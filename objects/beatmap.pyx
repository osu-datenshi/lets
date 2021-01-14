import time
import datetime

from common.log import logUtils as log
from common.constants import privileges
from constants import rankedStatuses
from helpers import beatmapHelper
from helpers import osuapiHelper
import objects.glob

class beatmap:
	__slots__ = ('artist', 'title', 'difficultyName', 'artistUnicode', 'titleUnicode',
	             "songName", "fileMD5", "rankedStatus", "rankedStatusFrozen",
							 "beatmapID", "beatmapSetID", 'creatorID', 'displayTitle', "offset",
	             "rating", "mode", "starsStd", "starsTaiko", "starsCtb", "starsMania", "AR", "OD", "maxCombo", "hitLength",
	             "bpm", 'updateDate', "rankingDate", "playcount" ,"passcount", "refresh", "fileName", 'isOsz2')

	def __init__(self, md5 = None, beatmapSetID = None, gameMode = 0, refresh=False, fileName=None):
		"""
		Initialize a beatmap object.

		md5 -- beatmap md5. Optional.
		beatmapSetID -- beatmapSetID. Optional.
		"""
		self.artist = ""
		self.title = ""
		self.difficultyName = ""
		self.artistUnicode = ""
		self.titleUnicode = ""
		self.songName = ""
		self.displayTitle = ''
		self.fileMD5 = ""
		self.fileName = fileName
		self.rankedStatus = rankedStatuses.NOT_SUBMITTED
		self.rankedStatusFrozen = 0
		self.beatmapID = 0
		self.beatmapSetID = 0
		self.creatorID = 0
		self.offset = 0		# Won't implement
		self.rating = 0.

		self.starsStd = 0.0
		self.starsTaiko = 0.0	# stars for converted
		self.starsCtb = 0.0		# stars for converted
		self.starsMania = 0.0	# stars for converted
		self.mode = 0
		self.AR = 0.0
		self.OD = 0.0
		self.maxCombo = 0
		self.hitLength = 0
		self.bpm = 0

		self.updateDate = 0
		self.rankingDate = 0
		
		# Statistics for ranking panel
		self.playcount = 0
		self.isOsz2 = False

		# Force refresh from osu api
		self.refresh = refresh

		if md5 is not None and beatmapSetID is not None:
			self.setData(md5, beatmapSetID)

	# Redundancy Plan:
	# Custom beatmaps have their own structure whilist the beatmaps dump is for auto-gen purposes. Please understand how shitty the API is.
	def addBeatmapToDB(self):
		"""
		Add current beatmap data in db if not in yet
		"""
		if self.fileMD5 is None:
			self.rankedStatus = rankedStatuses.NOT_SUBMITTED
			return
		
		# Make sure the beatmap is not already in db
		bdata = objects.glob.db.fetch(
			"SELECT id, ranked_status_freezed, ranked FROM beatmaps "
			"WHERE beatmap_md5 = %s OR beatmap_id = %s LIMIT 1",
			(self.fileMD5, self.beatmapID)
		)
		if bdata is not None:
			# This beatmap is already in db, remove old record
			# Get current frozen status
			frozen = bdata["ranked_status_freezed"]
			if frozen:
				self.rankedStatus = bdata["ranked"]
			# log.debug("Deleting old beatmap data ({})".format(bdata["id"]))
			# objects.glob.db.execute("DELETE FROM beatmaps WHERE id = %s LIMIT 1", [bdata["id"]])
		else:
			# Unfreeze beatmap status
			frozen = False

		if objects.glob.conf.extra["mode"]["rank-all-maps"] and not frozen:
			self.rankedStatus = 2

		# Add new beatmap data
		log.debug("Saving beatmap data in db...")
		params = {
			'beatmap_id': self.beatmapID,
			'beatmapset_id': self.beatmapSetID,
			'creator_id': self.creatorID,
			'beatmap_md5': self.fileMD5,
			'mode': self.mode,
			'artist': self.artist.encode("utf-8", "ignore").decode("utf-8"),
			'title': self.title.encode("utf-8", "ignore").decode("utf-8"),
			'difficulty_name': self.difficultyName.encode("utf-8", "ignore").decode("utf-8"),
			'artist_unicode': self.artistUnicode.encode("utf-8", "ignore").decode("utf-8"),
			'title_unicode': self.titleUnicode.encode("utf-8", "ignore").decode("utf-8"),
			'song_name': self.songName.encode("utf-8", "ignore").decode("utf-8"),
			'display_title': self.displayTitle.encode("utf-8", "ignore").decode("utf-8"),
			'ar': self.AR,
			'od': self.OD,
			'difficulty_std': self.starsStd,
			'difficulty_taiko': self.starsTaiko,
			'difficulty_ctb': self.starsCtb,
			'difficulty_mania': self.starsMania,
			'max_combo': self.maxCombo,
			'hit_length': self.hitLength,
			'bpm': self.bpm,
			'ranked': self.rankedStatus,
			'bancho_last_touch': self.updateDate,
			'latest_update': int(time.time()),
			'ranked_status_freezed': frozen
		}
		if self.fileName is not None:
			params['file_name'] = self.fileName
		
		# why delete then insert when you can just UPDATE the query... ripple oh ripple.
		if bdata is None:
			objects.glob.db.execute("INSERT INTO beatmaps ({keys}) VALUES ({values})".format(
				keys=', '.join(f"`{k}`" for k in params.keys()),
				values=', '.join(['%s'] * len(params))
			), params.values())
		else:
			objects.glob.db.execute("UPDATE beatmaps SET {kp} WHERE id = %s".format(
				kp=', '.join(f"{k} = %s" for k in params.keys())
			), list(params.values()) + [bdata['id']])

	def saveFileName(self, fileName):
		# Temporary workaround to avoid re-fetching all beatmaps from osu!api
		r = objects.glob.db.fetch("SELECT file_name FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1", (self.fileMD5,))
		if r is None:
			return
		if r["file_name"] is None:
			objects.glob.db.execute(
				"UPDATE beatmaps SET file_name = %s WHERE beatmap_md5 = %s LIMIT 1",
				(self.fileName, self.fileMD5)
			)

	def setDataFromDB(self, md5):
		"""
		Set this object's beatmap data from db.

		md5 -- beatmap md5
		return -- True if set, False if not set
		"""
		# Get data from DB
		data = objects.glob.db.fetch("SELECT * FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1", [md5])

		# Make sure the query returned something
		if data is None:
			return False

		# Make sure the beatmap is not an old one
		if data["difficulty_taiko"] == 0 and data["difficulty_ctb"] == 0 and data["difficulty_mania"] == 0:
			log.debug("Difficulty for non-std gamemodes not found in DB, refreshing data from osu!api...")
			return False

		# Set cached data period
		expire = int(objects.glob.conf.config["server"]["beatmapcacheexpire"])

		if not data['ranked_status_freezed']:
			# If the beatmap is ranked, we don't need to refresh data from osu!api that often
			if data["ranked"] >= rankedStatuses.RANKED:
				expire *= 3

			# Make sure the beatmap data in db is not too old
			if int(expire) > 0 and time.time() > data["latest_update"]+int(expire):
				return False

		# Data in DB, set beatmap data
		log.debug("Got beatmap data from db")
		self.setDataFromDict(data)
		return True

	def setDataFromDict(self, data):
		"""
		Set this object's beatmap data from data dictionary.

		data -- data dictionary
		return -- True if set, False if not set
		"""
		self.artist = data['artist'] or ""
		self.title = data['title'] or ""
		self.difficultyName = data['difficulty_name'] or ""
		self.artistUnicode = data['artist_unicode'] or self.artist
		self.titleUnicode = data['title_unicode'] or self.title
		self.songName = data["song_name"]
		self.fileMD5 = data["beatmap_md5"]
		self.rankedStatus = int(data["ranked"])
		self.rankedStatusFrozen = int(data["ranked_status_freezed"])
		self.beatmapID = int(data["beatmap_id"])
		self.beatmapSetID = int(data["beatmapset_id"])
		self.creatorID = int(data.get('creator_id',0))
		self.displayTitle = data['display_title'] or ''
		self.mode = int(data['mode'])
		self.AR = float(data["ar"])
		self.OD = float(data["od"])
		self.starsStd = float(data["difficulty_std"])
		self.starsTaiko = float(data["difficulty_taiko"])
		self.starsCtb = float(data["difficulty_ctb"])
		self.starsMania = float(data["difficulty_mania"])
		self.maxCombo = int(data["max_combo"])
		self.hitLength = int(data["hit_length"])
		self.bpm = int(data["bpm"])
		self.updateDate = int(data['bancho_last_touch'])
		# Ranking panel statistics
		self.playcount = int(data["playcount"]) if "playcount" in data else 0
		self.passcount = int(data["passcount"]) if "passcount" in data else 0

	def setDataFromOsuApi(self, md5, beatmapSetID):
		"""
		Set this object's beatmap data from osu!api.

		md5 -- beatmap md5
		beatmapSetID -- beatmap set ID, used to check if a map is outdated
		return -- True if set, False if not set
		"""
		# Check if osuapi is enabled
		mainData = None
		dataStd = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=0".format(md5))
		dataTaiko = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=1".format(md5))
		dataCtb = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=2".format(md5))
		dataMania = osuapiHelper.osuApiRequest("get_beatmaps", "h={}&a=1&m=3".format(md5))
		if dataStd is not None:
			mainData = dataStd
		elif dataTaiko is not None:
			mainData = dataTaiko
		elif dataCtb is not None:
			mainData = dataCtb
		elif dataMania is not None:
			mainData = dataMania

		# If the beatmap is frozen and still valid from osu!api, return True so we don't overwrite anything
		if mainData is not None and self.rankedStatusFrozen and self.beatmapSetID > 100000000:
			return True

		# Can't fint beatmap by MD5. The beatmap has been updated. Check with beatmap set ID
		if mainData is None:
			log.debug("osu!api data is None")
			dataStd = osuapiHelper.osuApiRequest("get_beatmaps", "s={}&a=1&m=0".format(beatmapSetID))
			dataTaiko = osuapiHelper.osuApiRequest("get_beatmaps", "s={}&a=1&m=1".format(beatmapSetID))
			dataCtb = osuapiHelper.osuApiRequest("get_beatmaps", "s={}&a=1&m=2".format(beatmapSetID))
			dataMania = osuapiHelper.osuApiRequest("get_beatmaps", "s={}&a=1&m=3".format(beatmapSetID))
			if dataStd is not None:
				mainData = dataStd
			elif dataTaiko is not None:
				mainData = dataTaiko
			elif dataCtb is not None:
				mainData = dataCtb
			elif dataMania is not None:
				mainData = dataMania

			if mainData is None:
				# Still no data, beatmap is not submitted
				return False
			else:
				# We have some data, but md5 doesn't match. Beatmap is outdated
				self.rankedStatus = rankedStatuses.NEED_UPDATE
				return True
		
		if not isinstance(mainData, dict):
			log.warning(f"Something is not right in here. Got {type(mainData)} instead.")
			return False

		# We have data from osu!api, set beatmap data
		obtainUnixClock = lambda t: int(time.mktime(datetime.datetime.strptime(t, "%Y-%m-%d %H:%M:%S").timetuple()))
		log.debug("Got beatmap data from osu!api")
		self.artist, self.title = mainData['artist'] or '', mainData['title'] or ''
		self.difficultyName = mainData['version'] or ''
		self.artistUnicode, self.titleUnicode = mainData['artist_unicode'] or self.artist, mainData['title_unicode'] or self.title
		self.songName = "{} - {} [{}]".format(self.artist, self.title, self.difficultyName)
		self.fileName = "{} - {} ({}) [{}].osu".format(
			self.artist, self.title, mainData["creator"], self.difficultyName,
		).replace("\\", "")
		self.displayTitle = f"[bold:0,size:20]{self.artistUnicode}|{self.titleUnicode}"
		self.fileMD5 = md5
		
		self.creatorID = int(mainData['creator_id'])
		self.updateDate = obtainUnixClock(mainData['last_update'])
		if mainData['approved_date']:
			self.rankingDate = obtainUnixClock(mainData['approved_date'])
		
		self.rankedStatus = convertRankedStatus(int(mainData["approved"]))
		self.beatmapID = int(mainData["beatmap_id"])
		self.beatmapSetID = int(mainData["beatmapset_id"])
		self.mode = int(mainData['mode'])
		self.AR = float(mainData["diff_approach"])
		self.OD = float(mainData["diff_overall"])

		# Determine stars for every mode
		self.starsStd = 0.0
		self.starsTaiko = 0.0
		self.starsCtb = 0.0
		self.starsMania = 0.0
		if dataStd is not None:
			self.starsStd = float(dataStd.get("difficultyrating", 0))
		if dataTaiko is not None:
			self.starsTaiko = float(dataTaiko.get("difficultyrating", 0))
		if dataCtb is not None:
			self.starsCtb = float(
				next((x for x in (dataCtb.get("difficultyrating"), dataCtb.get("diff_aim")) if x is not None), 0)
			)
		if dataMania is not None:
			self.starsMania = float(dataMania.get("difficultyrating", 0))

		self.maxCombo = int(mainData["max_combo"]) if mainData["max_combo"] is not None else 0
		self.hitLength = int(mainData["hit_length"])
		if mainData["bpm"] is not None:
			self.bpm = int(float(mainData["bpm"]))
		else:
			self.bpm = -1
		return True
	
	def setDataFromCustomBeatmaps(self, md5, beatmapSetID):
		"""
		i summon thou, custom meatbaps
		"""
		pass
	
	def setData(self, md5, beatmapSetID):
		"""
		Set this object's beatmap data from highest level possible.

		md5 -- beatmap MD5
		beatmapSetID -- beatmap set ID
		"""
		# Get beatmap from db
		dbResult = self.setDataFromDB(md5)

		# Force refresh from osu api.
		# We get data before to keep frozen maps ranked
		# if they haven't been updated
		if dbResult and self.refresh:
			dbResult = False

		if not dbResult:
			log.debug("Beatmap not found in db")
			# If this beatmap is not in db, get it from osu!api
			if self.beatmapSetID > 100000000:
				apiResult = self.setDataFromCustomBeatmaps(md5, beatmapSetID)
			else:
				apiResult = self.setDataFromOsuApi(md5, beatmapSetID)
				beatmapHelper.criteriaControl(self)
			beatmapHelper.autorankCheck(self)
			if not apiResult:
				# If it's not even in osu!api, this beatmap is not submitted
				self.rankedStatus = rankedStatuses.NOT_SUBMITTED
			elif self.rankedStatus not in (rankedStatuses.NOT_SUBMITTED, rankedStatuses.NEED_UPDATE):
				# We get beatmap data from osu!api, save it in db
				self.addBeatmapToDB()
		else:
			log.debug("Beatmap found in db")
			beatmapHelper.autorankCheck(self)

		log.debug("{}\n{}\n{}\n{}".format(self.starsStd, self.starsTaiko, self.starsCtb, self.starsMania))

	def getData(self, totalScores=0, version=4):
		"""
		Return this beatmap's data (header) for getscores

		return -- beatmap header for getscores
		"""
		# Fix loved maps for old clients
		if version < 4 and self.rankedStatus == rankedStatuses.LOVED:
			rankedStatusOutput = rankedStatuses.QUALIFIED
		else:
			rankedStatusOutput = self.rankedStatus
		
		end_data = [str(rankedStatusOutput), 'true' if self.isOsz2 else 'false']
		data = "{}|false".format(rankedStatusOutput)
		if self.rankedStatus not in (rankedStatuses.NOT_SUBMITTED, rankedStatuses.NEED_UPDATE, rankedStatuses.UNKNOWN):
			# If the beatmap is updated and exists, the client needs more data
			end_data.extend([self.beatmapID, self.beatmapSetID])
			end_data.append("\n".join(str(l) for l in [totalScores, self.offset, self.displayTitle, self.rating, '']))
			data += "|{}|{}|{}\n{}\n{}\n{}\n".format(self.beatmapID, self.beatmapSetID, totalScores, self.offset, self.displayTitle, self.rating)
			try:
				log.info('|'.join(end_data))
			except Exception:
				pass
		# Return the header
		return data
		# return '|'.join(end_data)

	def clearLeaderboard(self, hard=False):
		if not self.fileMD5:
			return
		if hard:
			objects.glob.db.execute('delete from scores where beatmap_md5 = %s',[self.fileMD5])
			objects.glob.db.execute('delete from scores_relax where beatmap_md5 = %s',[self.fileMD5])
		else:
			# this is done to recover scores easier than what you think ;)
			objects.glob.db.execute('update scores set completed = 0, pp = 0, score = 0 where beatmap_md5 = %s',[self.fileMD5])
			objects.glob.db.execute('update scores_relax set completed = 0, pp = 0, score = 0 where beatmap_md5 = %s',[self.fileMD5])
	
	def getCachedTillerinoPP(self):
		"""
		Returned cached pp values for 100, 99, 98 and 95 acc nomod
		(used ONLY with Tillerino, pp is always calculated with oppai when submitting scores)

		return -- list with pp values. [0,0,0,0] if not cached.
		"""
		data = objects.glob.db.fetch("SELECT pp_100, pp_99, pp_98, pp_95 FROM beatmaps WHERE beatmap_md5 = %s LIMIT 1", [self.fileMD5])
		if data is None:
			return [0,0,0,0]
		return [data["pp_100"], data["pp_99"], data["pp_98"], data["pp_95"]]

	def saveCachedTillerinoPP(self, l):
		"""
		Save cached pp for tillerino

		l -- list with 4 default pp values ([100,99,98,95])
		"""
		objects.glob.db.execute("UPDATE beatmaps SET pp_100 = %s, pp_99 = %s, pp_98 = %s, pp_95 = %s WHERE beatmap_md5 = %s", [l[0], l[1], l[2], l[3], self.fileMD5])

	@property
	def is_rankable(self):
		return self.rankedStatus >= rankedStatuses.RANKED and self.rankedStatus != rankedStatuses.UNKNOWN

def convertRankedStatus(approvedStatus):
	"""
	Convert approved_status (from osu!api) to ranked status (for getscores)

	approvedStatus -- approved status, from osu!api
	return -- rankedStatus for getscores
	"""

	approvedStatus = int(approvedStatus)
	if approvedStatus <= 0:
		return rankedStatuses.PENDING
	elif approvedStatus == 1:
		return rankedStatuses.RANKED
	elif approvedStatus == 2:
		return rankedStatuses.APPROVED
	elif approvedStatus == 3:
		return rankedStatuses.QUALIFIED
	elif approvedStatus == 4:
		return rankedStatuses.LOVED
	else:
		return rankedStatuses.UNKNOWN

def incrementPlaycount(md5, passed):
	"""
	Increment playcount (and passcount) for a beatmap

	md5 -- beatmap md5
	passed -- if True, increment passcount too
	"""
	objects.glob.db.execute(
		f"UPDATE beatmaps "
		f"SET playcount = playcount+1{', passcount = passcount+1' if passed else ''} "
		f"WHERE beatmap_md5 = %s LIMIT 1",
		[md5]
	)
