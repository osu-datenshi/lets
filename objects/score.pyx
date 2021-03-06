import time

import pp
from common.constants import gameModes, mods
from objects import beatmap
from common import generalUtils
from common.constants import gameModes
from common.log import logUtils as log
from common.ripple import userUtils
from constants import rankedStatuses
from common.ripple import scoreUtils
from objects import glob

RANKED_STATUS_COUNT   = [rankedStatuses.RANKED, rankedStatuses.APPROVED]
RANKED_STATUS_PARTIAL = [rankedStatuses.LOVED]
RANKED_STATUS_TEMP    = [rankedStatuses.QUALIFIED]

class baseScore:
	PP_CALCULATORS = pp.PP_CALCULATORS
	t = {
		'sl': 'scores'
	}
	rl = False
	__slots__ = ["scoreID", 'scoreChecksum', "playerName", "score", "maxCombo", "c50", "c100", "c300", "cMiss", "cKatu", "cGeki",
				 "fullCombo", "mods", "playerUserID","rank","date", "hasReplay", "fileMd5", "passed", "playDateTime",
				 "gameMode", "completed", "accuracy", "pp", "oldPersonalBest", "rankedScoreIncrease", "personalOldBestScore",
				 "_playTime", "_fullPlayTime", "quit", "failed"]
	def __init__(self, scoreID = None, rank = None, setData = True):
		"""
		Initialize a (empty) score object.

		scoreID -- score ID, used to get score data from db. Optional.
		rank -- score rank. Optional
		setData -- if True, set score data from db using scoreID. Optional.
		"""
		self.scoreID = 0
		self.scoreChecksum = ''
		self.playerName = "lil'demon"
		self.score = 0
		self.maxCombo = 0
		self.c50 = 0
		self.c100 = 0
		self.c300 = 0
		self.cMiss = 0
		self.cKatu = 0
		self.cGeki = 0
		self.fullCombo = False
		self.mods = 0
		self.playerUserID = 0
		self.rank = rank	# can be empty string too
		self.date = 0
		self.hasReplay = 0

		self.fileMd5 = None
		self.passed = False
		self.playDateTime = 0
		self.gameMode = 0
		self.completed = 0

		self.accuracy = 0.00

		self.pp = 0.00

		self.oldPersonalBest = 0
		self.rankedScoreIncrease = 0
		self.personalOldBestScore = None

		self._playTime = None
		self._fullPlayTime = None
		self.quit = None
		self.failed = None

		if scoreID is not None and setData:
			self.setDataFromDB(scoreID, rank)

	def _adjustedSeconds(self, x):
		if (self.mods & mods.DOUBLETIME) > 0:
			return x // 1.5
		elif (self.mods & mods.HALFTIME) > 0:
			return x // 0.75
		return x

	@property
	def r(self):
		return type(self).rl
	
	@property
	def fullPlayTime(self):
		return self._fullPlayTime

	@fullPlayTime.setter
	def fullPlayTime(self, value):
		value = max(0, value)
		self._fullPlayTime = self._adjustedSeconds(value)

	@property
	def playTime(self):
		return self._playTime

	@playTime.setter
	def playTime(self, value):
		value = max(0, value)
		value = self._adjustedSeconds(value)
		# Do not consider the play time at all if it's greater than the length of the map + 1/3
		# This is because the client sends the ms when the player failed relative to the
		# song (audio file) start, so compilations and maps with super long introductions
		# break the system without this check
		if self.fullPlayTime is not None and value > self.fullPlayTime * 1.33:
			value = 0
		self._playTime = value

	@property
	def visibleScore(self):
		return not(userUtils.InvisibleBoard(self.playerUserID) & 2)
	
	def calculateAccuracy(self):
		"""
		Calculate and set accuracy for that score
		"""
		self.accuracy = 0
		hit_factors = []
		hit_weights = []
		if self.gameMode == 0:
			# std
			hit_factors.extend('Miss 50 100 300'.split())
			hit_weights.extend([0, 50, 100, 300])
		elif self.gameMode == 1:
			# taiko
			hit_factors.extend('Miss 100 300'.split())
			hit_weights.extend([0, 150, 300])
		elif self.gameMode == 2:
			# ctb
			hit_factors.extend('Miss Katu 50 100 300'.split())
			hit_weights.extend([0, 0, 1, 1, 1])
		elif self.gameMode == 3:
			# mania
			hit_factors.extend('Miss 50 100 Katu 300 Geki'.split())
			hit_weights.extend([0, 50, 100, 200, 300, 300])
		else:
			# unknown gamemode
			return
		if not (hit_factors and hit_weights):
			return
		max_weight = max(hit_weights)
		total_hits = sum(getattr(self, f"c{k}") for k in hit_factors)
		if total_hits == 0:
			self.accuracy = 1
		else:
			total_base = sum(hit_weights[i] * getattr(self, f"c{hit_factors[i]}") for i in range(len(hit_weights)))
			self.accuracy = total_base / (total_hits * max_weight)

	def setRank(self, rank):
		"""
		Force a score rank

		rank -- new score rank
		"""
		self.rank = rank
			
	def setDataFromDB(self, scoreID, rank = None):
		"""
		Set this object's score data from db
		Sets playerUserID too

		scoreID -- score ID
		rank -- rank in scoreboard. Optional.
		"""
		
		data = glob.db.fetch(f"SELECT s.*, users.username FROM {type(self).t['sl']} as s LEFT JOIN users ON users.id = s.userid WHERE s.id = %s LIMIT 1", [scoreID])
		if data is not None:
			self.setDataFromDict(data, rank)

	def setDataFromDict(self, data, rank = None):
		"""
		Set this object's score data from dictionary
		Doesn't set playerUserID

		data -- score dictionarty
		rank -- rank in scoreboard. Optional.
		"""
		#print(str(data))
		self.scoreID = data["id"]
		self.scoreChecksum = data['checksum']
		if "username" in data:
			self.playerName = userUtils.getClan(data["userid"])
		else:
			self.playerName = userUtils.getUsername(data["userid"])
		self.playerUserID = data["userid"]
		self.score = data["score"]
		self.maxCombo = data["max_combo"]
		self.gameMode = data["play_mode"]
		self.c50 = data["50_count"]
		self.c100 = data["100_count"]
		self.c300 = data["300_count"]
		self.cMiss = data["misses_count"]
		self.cKatu = data["katus_count"]
		self.cGeki = data["gekis_count"]
		self.fullCombo = data["full_combo"] == 1
		self.mods = data["mods"]
		self.rank = rank if rank is not None else ""
		self.date = data["time"]
		self.fileMd5 = data["beatmap_md5"]
		self.completed = data["completed"]
		#if "pp" in data:
		self.pp = data["pp"]
		self.calculateAccuracy()

	def setDataFromScoreData(self, scoreData, quit_=None, failed=None):
		"""
		Set this object's score data from scoreData list (submit modular)

		scoreData -- scoreData list
		"""
		if len(scoreData) >= 16:
			self.fileMd5 = scoreData[0]
			self.playerName = scoreData[1].strip()
			self.scoreChecksum = scoreData[2]
			self.c300 = int(scoreData[3])
			self.c100 = int(scoreData[4])
			self.c50 = int(scoreData[5])
			self.cGeki = int(scoreData[6])
			self.cKatu = int(scoreData[7])
			self.cMiss = int(scoreData[8])
			self.score = int(scoreData[9])
			self.maxCombo = int(scoreData[10])
			self.fullCombo = scoreData[11] == 'True'
			#self.rank = scoreData[12]
			self.mods = int(scoreData[13])
			self.passed = scoreData[14] == 'True'
			self.gameMode = int(scoreData[15])
			#self.playDateTime = int(scoreData[16])
			self.playDateTime = int(time.time())
			self.calculateAccuracy()
			#osuVersion = scoreData[17]
			self.quit = quit_
			self.failed = failed

			# Set completed status
			self.setCompletedStatus()


	# replaced with key for further overrides
	def getData(self, key='score'):
		"""Return score row relative to this score for getscores"""
		return "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|1\n".format(
			self.scoreID,
			self.playerName,
			int(getattr(self, key)),
			self.maxCombo,
			self.c50,
			self.c100,
			self.c300,
			self.cMiss,
			self.cKatu,
			self.cGeki,
			self.fullCombo,
			self.mods,
			self.playerUserID,
			self.rank,
			self.date
		)

	def setCompletedStatus(self, b = None):
		"""
		Set this score completed status and rankedScoreIncrease
		"""
		try:
			self.completed = 0
			
			# Create beatmap object
			if b is None:
				b = beatmap.beatmap(self.fileMd5, 0)
				
			if not scoreUtils.isRankable(self.mods):
				return
			
			# Get userID
			userID = userUtils.getID(self.playerName)
			# Make sure we don't have another score identical to this one
			duplicate = glob.db.fetch(f"SELECT id FROM {type(self).t['sl']} WHERE userid = %s AND beatmap_md5 = %s AND play_mode = %s AND score = %s AND checksum = %s LIMIT 1", [userID, self.fileMd5, self.gameMode, self.score, self.scoreChecksum])
			if duplicate is not None:
				# Found same score in db. Don't save this score.
				self.completed = -1
				return
			
			if self.passed:
				# No duplicates found.
				# Get right "completed" value
				loved_nopp = glob.conf.extra["lets"]["submit"]["loved-dont-give-pp"]
				if hasattr(userUtils,'ScoreOverrideType'):
					score_key = userUtils.ScoreOverrideType(userID, self.rl)
				else:
					score_key = glob.conf.extra["lets"]["submit"]["score-overwrite"]
				score_keys = ['score']
				if score_key != 'score':
					score_keys.insert(0, score_key)
				if b.rankedStatus == rankedStatuses.LOVED and loved_nopp:
					personalBest = glob.db.fetch(f"SELECT id, score FROM {type(self).t['sl']} WHERE userid = %s AND beatmap_md5 = %s AND play_mode = %s AND completed = 3 LIMIT 1", [userID, self.fileMd5, self.gameMode])
				else:
					personalBest = glob.db.fetch("SELECT id, {} FROM {} WHERE userid = %s AND beatmap_md5 = %s AND play_mode = %s AND completed = 3 LIMIT 1".format(
						", ".join(score_keys),
						type(self).t['sl']
					), [userID, self.fileMd5, self.gameMode])
				if personalBest is None:
					# This is our first score on this map, so it's our best score
					self.completed = 3
					self.rankedScoreIncrease = self.score
					self.oldPersonalBest = 0
					self.personalOldBestScore = None
				else:
					# Set old personal best and calculates PP
					self.personalOldBestScore = personalBest["id"]
					# Compare personal best's score with current score
					count_override = False
					if b.rankedStatus in RANKED_STATUS_COUNT:
						count_override = True
					elif b.rankedStatus in RANKED_STATUS_PARTIAL:
						count_override = not loved_nopp
					elif b.rankedStatus in RANKED_STATUS_TEMP:
						pass
					self.rankedScoreIncrease = self.score-personalBest["score"]
					self.oldPersonalBest = personalBest["id"]
					if count_override:
						self.calculatePP()
						"""
						Allow score overtake if respective score key is the same one
						"""
						self.completed = 2
						for key in score_keys:
							currentScore = getattr(self, key)
							if currentScore == personalBest[key]:
								continue
							elif currentScore > personalBest[key]:
								self.completed = 3
								break
							elif currentScore < personalBest[key]:
								break
						pass # NOTE: score regarded as non-personal best by any means unless one of criterion is beaten.
					else:
						self.completed = 3 if self.score > personalBest["score"] else 2
			elif self.quit:
				self.completed = 0
			elif self.failed:
				self.completed = 1
		finally:
			if userID == 3:
				log.info("Completed status: {}".format(self.completed))
			log.debug("Completed status: {}".format(self.completed))

	def saveScoreInDB(self):
		"""
		Save this score in DB (if passed and mods are valid)
		"""
		# Add this score
		if self.completed >= 0:
			query = f"INSERT INTO {type(self).t['sl']} (id, beatmap_md5, checksum, userid, score, max_combo, full_combo, mods, 300_count, 100_count, 50_count, katus_count, gekis_count, misses_count, `time`, play_mode, playtime, completed, accuracy, pp) VALUES (NULL, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);"
			self.scoreID = int(glob.db.execute(query, [self.fileMd5, self.scoreChecksum, userUtils.getID(self.playerName), self.score, self.maxCombo, int(self.fullCombo), self.mods, self.c300, self.c100, self.c50, self.cKatu, self.cGeki, self.cMiss, self.playDateTime, self.gameMode, self.playTime if self.playTime is not None and not self.passed else self.fullPlayTime, self.completed, self.accuracy * 100, self.pp]))

			# Set old personal best to completed = 2
			if self.oldPersonalBest != 0 and self.completed == 3:
				glob.db.execute(f"UPDATE {type(self).t['sl']} SET completed = 2 WHERE id = %s AND completed = 3 LIMIT 1", [self.oldPersonalBest])

			# Update counters in redis
			glob.redis.incr("ripple:total_submitted_scores", 1)
			glob.redis.incr("ripple:total_pp", int(self.pp))
		glob.redis.incr("ripple:total_plays", 1)

	def calculatePP(self, b = None):
		"""
		Calculate this score's pp value if completed == 3
		"""
		# Create beatmap object
		if b is None:
			b = beatmap.beatmap(self.fileMd5, 0)

		# Calculate pp
		precond    = scoreUtils.isRankable(self.mods) and self.passed and self.gameMode in type(self).PP_CALCULATORS
		loved_nopp = glob.conf.extra["lets"]["submit"]["loved-dont-give-pp"] # OK FIRST OF ALL, WHO TF WANTS LOVED FOR A PP?????
		self.pp = 0
		if not precond:
			return
		if b.rankedStatus == rankedStatuses.UNKNOWN:
			return
		if b.rankedStatus in RANKED_STATUS_COUNT:
			calculator = type(self).PP_CALCULATORS[self.gameMode](b, self)
			self.pp = calculator.pp
		elif b.rankedStatus in RANKED_STATUS_PARTIAL and not loved_nopp:
			calculator = type(self).PP_CALCULATORS[self.gameMode](b, self)
			self.pp = calculator.pp

class standardScore(baseScore):
	pass

# this is intended
from pp import relaxoppai, rippoppai, wifipiano2, cicciobello
class relaxScore(baseScore):
	PP_CALCULATORS = baseScore.PP_CALCULATORS.copy()
	PP_CALCULATORS.update(pp.PP_RELAX_CALCULATORS)
	
	t = baseScore.t.copy()
	t['sl'] = 'scores_relax'
	rl = True
	pass

# FIXME: what the fuck is this actually.
class PerfectScoreFactory:
	@staticmethod
	def create(beatmap, game_mode=gameModes.STD):
		"""
		Factory method that creates a perfect score.
		Used to calculate max pp amount for a specific beatmap.

		:param beatmap: beatmap object
		:param game_mode: game mode number. Default: `gameModes.STD`
		:return: `score` object
		"""
		s = standardScore()
		s.accuracy = 1.
		# max combo cli param/arg gets omitted if it's < 0 and oppai/catch-the-pp set it to max combo.
		# maniapp ignores max combo entirely.
		s.maxCombo = -1
		s.fullCombo = True
		s.passed = True
		s.gameMode = game_mode
		if s.gameMode == gameModes.MANIA:
			s.score = 1000000
		return s
