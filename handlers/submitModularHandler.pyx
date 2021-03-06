import base64
import collections
import json
import sys
import threading
import traceback
from urllib.parse import urlencode
import math

import requests
import tornado.gen
import tornado.web

import secret.achievements.utils
from common import generalUtils
from common.constants import gameModes
from common.constants import mods
from common.constants import privileges
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import replayHelper
from helpers import leaderboardHelper
from helpers.generalHelper import zingonify, getHackByFlag
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from objects.charts import BeatmapChart, OverallChart
from secret import butterCake
from discord_webhook import DiscordWebhook, DiscordEmbed

MODULE_NAME = "submit_modular"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		newCharts = self.request.uri == "/web/osu-submit-modular-selector.php"
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# Check arguments
			if glob.conf.extra["lets"]["submit"]["ignore-x-flag"]:
				if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass"]):
					raise exceptions.invalidArgumentsException(MODULE_NAME)
			else:
				if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass", "x"]):
					raise exceptions.invalidArgumentsException(MODULE_NAME)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()
			if glob.conf.extra["lets"]["submit"]["ignore-x-flag"]:
				quit_ = 0
			else:
				quit_ = self.get_argument("x") == "1"
			try:
				failTime = max(0, int(self.get_argument("ft", 0)))
			except ValueError:
				raise exceptions.invalidArgumentsException(MODULE_NAME)
			failed = not quit_ and failTime > 0

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None

			# Get right AES Key
			if "osuver" in self.request.arguments:
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")
			if len(scoreData) < 16 or len(scoreData[0]) != 32:
				return
			username = scoreData[1].strip()

			# Login and ban check
			userID = userUtils.getID(username)
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
				
			 # Score submission lock check
			lock_key = "lets:score_submission_lock:{}:{}:{}".format(userID, scoreData[0], scoreData[2])
			if glob.redis.get(lock_key) is not None:
				# The same score score is being submitted and it's taking a lot
				log.warning("Score submission blocked because there's a submission lock in place ({})".format(lock_key))
				return
 
			# Set score submission lock
			log.debug("Setting score submission lock {}".format(lock_key))
			glob.redis.set(lock_key, "1", 120)
 
				
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Get variables for relax
			prefixes = 'VANILLA RELAX SCOREV2'.split()
			cpi = 0
			
			used_mods = int(scoreData[13])
			UsingRelax = used_mods & 128
			if used_mods & mods.SCOREV2: # put some V2 guard for now (I have a plan to implement separate system with this)
				cpi = 2
				self.write('ok')
				glob.redis.delete(lock_key)
				return
			if UsingRelax:
				cpi = 1

			# Create score object and set its data
			log.info("[{}] {} has submitted a score on {}...".format(prefixes[cpi], username, scoreData[0]))
			
			scoreClass = score.standardScore
			if UsingRelax:
				scoreClass = score.relaxScore
			s = scoreClass()
			s.setDataFromScoreData(scoreData, quit_=quit_, failed=failed)
			s.playerUserID = userID

			if s.completed == -1:
				# Duplicated score
				log.warning("Duplicated score detected, this is normal right after restarting the server")
				return

			# Set score stuff missing in score data
			s.playerUserID = userID

			# Get beatmap info
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)

			# Make sure the beatmap is submitted and updated
			#if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
			#	log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
			#	return

			# Check if the ranked status is allowed
			if beatmapInfo.rankedStatus not in glob.conf.extra["_allowed_beatmap_rank"]:
				log.debug("Beatmap's rankstatus is not allowed to be submitted. Score submission aborted.")
				return

			# Set play time and full play time
			s.fullPlayTime = beatmapInfo.hitLength
			if quit_ or failed:
				s.playTime = failTime // 1000

			# Calculate PP
			length = 0
			if s.passed and beatmapInfo.beatmapID < 100000000:
				length = userUtils.getBeatmapTime(beatmapInfo.beatmapID)
			else:
				length = math.ceil(int(self.get_argument("ft")) / 1000)
			if UsingRelax:
				userUtils.incrementPlaytimeRX(userID, s.gameMode, length)
			else:
				userUtils.incrementPlaytime(userID, s.gameMode, length)
			midPPCalcException = None
			
			# Send message
			def send_bot_message(msg):
				safe_user = username.encode().decode("ASCII", "ignore")
				alert = "{}, {}".format(safe_user, msg)
				params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": safe_user, "msg": alert})
				requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
			
			try:
				retry = 5
				while retry > 0:
					try:
						s.calculatePP()
					except Exception as e:
						retry -= 1
						if retry > 0:
							pass
						else:
							raise e
					else:
						retry = 0
			except Exception as e:
				# Intercept ALL exceptions and bypass them.
				# We want to save scores even in case PP calc fails
				# due to some rippoppai bugs.
				# I know this is bad, but who cares since I'll rewrite
				# the scores server again.
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				send_bot_message("PP calculation error happened. Please poke us at Discord for details. Make sure it's fast enough, okay?")
				s.pp = 0
				midPPCalcException = e
			
			# Do Restrict
			def do_restrict(reason, note=None, warnlog=None):
				userUtils.restrict(userID)
				if note:
					userUtils.appendNotes(userID, note)
				if warnlog:
					log.warning(warnlog)
				if glob.conf.config["discord"]["enable"]:
					dcnel = glob.conf.config["discord"]["autobanned"]
					webhook = DiscordWebhook(url=dcnel)
					embed = DiscordEmbed(title='NEW CHEATER DETECTED!!', description=reason, color=16711680)
					webhook.add_embed(embed)
					webhook.execute()
				log.info("CHEATER GOBLOK MASUK DISCORD")
			
			# Do Ban
			def do_ban(reason, note=None, warnlog=None):
				userUtils.ban(userID)
				if note:
					userUtils.appendNotes(userID, note)
				if warnlog:
					log.warning(warnlog)
				if glob.conf.config["discord"]["enable"]:
					dcnel = glob.conf.config["discord"]["autobanned"]
					webhook = DiscordWebhook(url=dcnel)
					embed = DiscordEmbed(title='NEW CHEATER DETECTED!!', description=reason, color=16711680)
					webhook.add_embed(embed)
					log.info("CHEATER GOBLOK MASUK DISCORD")
					webhook.execute()
			
			# Restrict obvious cheaters
			is_fullmod  = bool( (s.mods & (mods.DOUBLETIME | mods.NIGHTCORE)) and (s.mods & mods.FLASHLIGHT) and (s.mods & mods.HARDROCK) and (s.mods & mods.HIDDEN) )
			userOverPP = False
			invalidPP = 0
			if not restricted:
				limit_pp, var_limit, can_limit, pp_total_max = userUtils.obtainPPLimit(userID, s.gameMode, relax=bool(UsingRelax), modded=is_fullmod)
				relax = 1 if used_mods & 128 else 0
				
				freeLimitFlags = userUtils.noPPLimit(userID, relax)
				null_over_pp = glob.conf.extra['lets']['submit'].get('null-over-pp',False)
				null_mode_pp = limit_pp <= 0
				if relax:
					userStat = userUtils.getUserStatsRx(userID, s.gameMode)
				else:
					userStat = userUtils.getUserStats(userID, s.gameMode)
				singleScoreFlag = freeLimitFlags & 1
				totalPPFlag     = freeLimitFlags & 2
				userOverPP      = userStat['pp'] >= pp_total_max and not totalPPFlag
				
				if userOverPP:
					null_over_pp, null_mode_pp = True, False
				
				if null_mode_pp:
					invalidPP = 1
				elif (userOverPP) or (s.pp >= limit_pp and not singleScoreFlag) and not glob.conf.extra["mode"]["no-pp-cap"]:
					if null_over_pp:
						# forgive the user but nullify the PP gain for this run.
						invalidPP = 1
						if userOverPP:
							invalidPP = 2
							warning_message = "looks like your total PP is past-verification requirement. Please submit a prove to the staff that you played legit to continue."
						elif can_limit:
							warning_message = "looks like your PP gain for this play is over than what you should be able to. Please try again later once you've gained enough PP."
						elif var_limit and is_fullmod:
							warning_message = "looks like your PP gain is too high. This score won't yield PP."
						else:
							warning_message = "looks like your PP gain is too high. This score won't yield PP."
						send_bot_message("[{}] {}".format(prefixes[cpi], warning_message))
					else:
						do_restrict('**{}** ({}) has been restricted due to too high pp gain and too brutal ({}pp)'.format(username, userID, s.pp), note="Restricted due to too high pp gain ({}pp)".format(s.pp))
				if (userUtils.PPScoreInformation(userID, relax) if hasattr(userUtils,'PPScoreInformation') else (userID == 3)) and not userOverPP and int(s.pp) > 0:
					send_bot_message("You obtained {:.1f}/{:d}pp. Current mode total PP limit is {:d}pp".format(s.pp, limit_pp, pp_total_max))

			# Check notepad hack
			if bmk is None and bml is None:
				# No bmk and bml params passed, edited or super old client
				#log.warning("{} ({}) most likely submitted a score from an edited client or a super old client".format(username, userID), "cm")
				pass
			elif bmk != bml and not restricted:
				# bmk and bml passed and they are different, restrict the user
				do_restrict('**{}** ({}) has been restricted due to notepad hack'.format(username, userID), \
					note="Restricted due to notepad hack", \
					warnlog="**{}** ({}) has been restricted due to notepad hack".format(username, userID))
				return
			
			# Right before submitting the score, get the personal best score object (we need it for charts)
			scoreboardClass = scoreboard.standard
			if UsingRelax:
				scoreboardClass = scoreboard.relax
			if s.passed and s.oldPersonalBest > 0:
				oldPersonalBestRank = glob.personalBestCacheRX.get(userID, s.fileMd5) if UsingRelax else glob.personalBestCache.get(userID, s.fileMd5)
				if oldPersonalBestRank == 0:
					# oldPersonalBestRank not found in cache, get it from db through a scoreboard object
					oldScoreboard = scoreboardClass(username, s.gameMode, beatmapInfo, False)
					oldScoreboard.setPersonalBestRank()
					oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
				oldPersonalBest = scoreClass(s.oldPersonalBest, oldPersonalBestRank)
			else:
				oldPersonalBestRank = 0
				oldPersonalBest = None
			if invalidPP == 2:
				log.warning(f"Invalid PP: Over Limit {s.gameMode}/{UsingRelax} {userID} {s.pp}")
				if oldPersonalBest:
					s.pp = min(oldPersonalBest.pp, s.pp) # PP cap. but allow score overtake.
				else:
					s.pp = 0
			elif invalidPP == 1:
				s.pp = -1
			
			# Save score in db
			s.saveScoreInDB()
				
			# Remove lock as we have the score in the database at this point
			# and we can perform duplicates check through MySQL
			log.debug("Resetting score lock key {}".format(lock_key))
			glob.redis.delete(lock_key)
			
			# Client anti-cheat flags
			if not restricted and glob.conf.extra["mode"]["anticheat"]:
				haxFlags = scoreData[17].count(' ') # 4 is normal, 0 is irregular but inconsistent.
				if haxFlags not in (0,4) and s.passed:
					hack = getHackByFlag(int(haxFlags))
					if type(hack) == str:
						# THOT DETECTED
						if glob.conf.config["discord"]["enable"]:
							webhook = DiscordWebhook(url=glob.conf.config["discord"]["ahook"])
							embed = DiscordEmbed(title='This is worst cheater', color=242424)
							embed = DiscordEmbed(name='Catched some cheater {username} ({userID})')
							embed = DiscordEmbed(description='This body catched with flag {haxFlags}\nIn enuming: {hack}')

							if glob.conf.extra["mode"]["anticheat"]:
								webhook.add_embed(embed)
								webhook.execute()

			'''
			ignoreFlags = 4
			if glob.debug:
				# ignore multiple client flags if we are in debug mode
				ignoreFlags |= 8
			haxFlags = (len(scoreData[17])-len(scoreData[17].strip())) & ~ignoreFlags
			if haxFlags != 0 and not restricted:
				userHelper.restrict(userID)
				userHelper.appendNotes(userID, "-- Restricted due to clientside anti cheat flag ({}) (cheated score id: {})".format(haxFlags, s.scoreID))
				log.warning("**{}** ({}) has been restricted due clientside anti cheat flag **({})**".format(username, userID, haxFlags), "cm")
			'''

			# bad integer score
			int64_max = (1 << 63) - 1
			norm_max  = 1000000
			if s.score < 0 or s.score > int64_max:
				if glob.conf.extra["mode"]["anticheat"]:
					do_ban('**{}** ({}) has been banned due to negative score (score submitter)'.format(username, userID), note="Banned due to negative score (score submitter)")
				else:
					send_bot_message("seems like you've submitted an invalid score value, this score won't submit for you.")
				return

			# Make sure the score is not memed
			if s.gameMode == gameModes.MANIA and s.score > norm_max:
				if glob.conf.extra["mode"]["anticheat"]:
					do_ban('**{}** ({}) has been banned due to invalid score (score submitter)'.format(username, userID), note="Banned due to invalid score (score submitter)")
				else:
					send_bot_message("seems like you've exceed osu!mania score limit (1000000), this score won't submit for you.")
				return
			
			def impossible_mods():
				# Impossible Flags
				# - DT/NC and HT together
				# - HR and EM together
				# - Fail Control Mods are toggled exclusively (SD/PF and NF, SD/PF and RL/ATP, NF and RL/ATP)
				# - Relax variant are toggled exclusively (RL and ATP)
				time_control = (s.mods & (mods.DOUBLETIME | mods.NIGHTCORE), s.mods & mods.HALFTIME)
				fail_control = (s.mods & (mods.SUDDENDEATH | mods.PERFECT), s.mods & mods.NOFAIL, s.mods & mods.RELAX, s.mods & mods.RELAX2)
				key_control = [(s.mods & (1 << kt)) for kt in [15,16,17,18,19,24,26,27,28]]
				all_controls = [time_control, fail_control, key_control]
				over_controls = False
				for ctrl in all_controls:
					if over_controls:
						break
					over_controls = over_controls or (len([c for c in ctrl if c]) > 1)
				return False or \
					((s.mods & mods.HARDROCK) and (s.mods & mods.EASY)) or \
					over_controls or \
					False
			
			# Ci metto la faccia, ci metto la testa e ci metto il mio cuore
			if impossible_mods():
				if glob.conf.extra["mode"]["anticheat"]:
					do_ban('**{}** ({}) has been detected using impossible mod combination {} (score submitter)'.format(username, userID, s.mods), \
					  note="Impossible mod combination {} (score submitter)".format(s.mods))
				else:
					send_bot_message("seems like you've used osu! score submitter limit (Impossible mod combination), this score won't submit for you.")
					return

			# NOTE: Process logging was removed from the client starting from 20180322
			if s.completed == 3 and "pl" in self.request.arguments:
				butterCake.bake(self, s)
				
			# Save replay for all passed scores
			# Make sure the score has an id as well (duplicated?, query error?)
			if s.passed and s.scoreID > 0 and s.completed == 3:
				if "score" in self.request.files:
					# Save the replay if it was provided
					log.debug("Saving replay ({})...".format(s.scoreID))
					replay = self.request.files["score"][0]["body"]

					if UsingRelax:
						with open("{}_relax/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], (s.scoreID)), "wb") as f:
							f.write(replay)
					else:
						with open("{}/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], (s.scoreID)), "wb") as f:
							f.write(replay)

					if glob.conf.config["cono"]["enable"]:
						RPBUILD = replayHelper.buildFullReplay
						# We run this in a separate thread to avoid slowing down scores submission,
						# as cono needs a full replay
						threading.Thread(target=lambda: glob.redis.publish(
							"cono:analyze", json.dumps({
								"score_id": s.scoreID,
								"beatmap_id": beatmapInfo.beatmapID,
								"user_id": s.playerUserID,
								"game_mode": s.gameMode,
								"pp": s.pp,
								"completed": s.completed,
								"replay_data": base64.b64encode(
									RPBUILD(
										s.scoreID,
										rawReplay=self.request.files["score"][0]["body"],
										relax=UsingRelax
									)
								).decode(),
							})
						)).start()
				else:
					# Restrict if no replay was provided
					if not restricted:
						do_restrict(
							'**{}** ({}) has been restricted due to not submitting a replay on map ({})'.format(username, userID, s.fileMd5),
							note="Restricted due to missing replay while submitting a score.", \
							warnlog="**{}** ({}) has been restricted due to not submitting a replay on map {}.".format(username, userID, s.fileMd5) \
						)

			# Update beatmap playcount (and passcount)
			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			# Let the api know of this score
			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)

			# Re-raise pp calc exception after saving score, cake, replay etc
			# so Sentry can track it without breaking score submission
			if midPPCalcException is not None:
				raise ppCalcException(midPPCalcException)

			# If there was no exception, update stats and build score submitted panel
			# Get "before" stats for ranking panel (only if passed)
			if s.passed:
				# Get stats and rank
				oldUserStats = glob.userStatsCacheRX.get(userID, s.gameMode) if UsingRelax else glob.userStatsCache.get(userID, s.gameMode)
				oldRank = userUtils.getGameRankRx(userID, s.gameMode) if UsingRelax else userUtils.getGameRank(userID, s.gameMode)

			# Always update users stats (total/ranked score, playcount, level, acc and pp)
			# even if not passed
			log.debug("Updating {}'s stats...".format(username))
			if UsingRelax:
				userUtils.updateStatsRx(userID, s)
				userUtils.incrementUserBeatmapPlaycountRX(userID, s.gameMode, beatmapInfo.beatmapID)
			else:
				userUtils.updateStats(userID, s)
				userUtils.incrementUserBeatmapPlaycount(userID, s.gameMode, beatmapInfo.beatmapID)

			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:
				# Get new stats
				if UsingRelax:
					newUserStats = userUtils.getUserStatsRx(userID, s.gameMode)
					glob.userStatsCacheRX.update(userID, s.gameMode, newUserStats)
					leaderboardHelper.update(userID, newUserStats["pp"], s.gameMode, relax=True)
					maxCombo = userUtils.getMaxComboRX(userID, s.gameMode)
				else:
					newUserStats = userUtils.getUserStats(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserStats)
					leaderboardHelper.update(userID, newUserStats["pp"], s.gameMode)
					maxCombo = userUtils.getMaxCombo(userID, s.gameMode)

				# Update leaderboard (global and country) if score/pp has changed
				if s.completed == 3 and newUserStats["pp"] != oldUserStats["pp"]:
					leaderboardHelper.update(userID, newUserStats["pp"], s.gameMode, relax=UsingRelax)
					leaderboardHelper.updateCountry(userID, newUserStats["pp"], s.gameMode, relax=UsingRelax)
					if not restricted and newUserStats['pp'] >= pp_total_max and not totalPPFlag:
						send_bot_message("hello my fellow little demon! I heard that your performance on {}'s {} is rather outstanding! Why not submit yourself to our guild for an access to next dungeon?".format(gameModes.getGamemodeFull(s.gameMode), prefixes[cpi]))

			# Update total hits
			if UsingRelax:
				userUtils.updateTotalHitsRX(score=s)
			else:
				userUtils.updateTotalHits(score=s)
			# TODO: Update max combo
			
			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")
			oldStats = userUtils.getUserStats(userID, s.gameMode)

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = False

			# At the end, check achievements
			if s.passed:
				new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserStats)

			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed:
				log.debug("Started building ranking panel")

				# Trigger bancho stats cache update
				glob.redis.publish("peppy:update_cached_stats", userID)

				# Get personal best after submitting the score
				newScoreboard = scoreboardClass(username, s.gameMode, beatmapInfo, False)

				newScoreboard.setPersonalBestRank()
				personalBestID = newScoreboard.getPersonalBest()
				assert personalBestID is not None
					
				currentPersonalBest = scoreClass(personalBestID, newScoreboard.personalBestRank)

				# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
				rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode, relax=s.mods & 128)

				# Output dictionary
				if newCharts:
					log.debug("Using new charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount + 1),
							("beatmapPasscount", beatmapInfo.passcount + (s.completed == 3)),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						BeatmapChart(
							oldPersonalBest if s.completed == 3 else currentPersonalBest,
							currentPersonalBest if s.completed == 3 else s,
							beatmapInfo.beatmapID,
						),
						OverallChart(
							userID, oldUserStats, newUserStats, s, new_achievements, oldRank, rankInfo["currentRank"]
						)
					]
				else:
					log.debug("Using old charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount),
							("beatmapPasscount", beatmapInfo.passcount),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						collections.OrderedDict([
							("chartId", "overall"),
							("chartName", "Overall Ranking"),
							("chartEndDate", ""),
							("beatmapRankingBefore", oldPersonalBestRank),
							("beatmapRankingAfter", newScoreboard.personalBestRank),
							("rankedScoreBefore", oldUserStats["rankedScore"]),
							("rankedScoreAfter", newUserStats["rankedScore"]),
							("totalScoreBefore", oldUserStats["totalScore"]),
							("totalScoreAfter", newUserStats["totalScore"]),
							("playCountBefore", newUserStats["playcount"]),
							("accuracyBefore", float(oldUserStats["accuracy"])/100),
							("accuracyAfter", float(newUserStats["accuracy"])/100),
							("rankBefore", oldRank),
							("rankAfter", rankInfo["currentRank"]),
							("toNextRank", rankInfo["difference"]),
							("toNextRankUser", rankInfo["nextUsername"]),
							("achievements", ""),
							("achievements-new", secret.achievements.utils.achievements_response(new_achievements)),
							("onlineScoreId", s.scoreID)
						])
					]
				output = "\n".join(zingonify(x) for x in dicts)

				# Some debug messages
				log.debug("Generated output for online ranking screen!")
				log.debug(output)
				# TESTING TO USERLOGS
				withSpecial = ''
				if UsingRelax:
					withSpecial = 'with ' + ('RL' if userID == 3 else 'RX') # im still questioning who invented this shitty abbreviation.
				messages = [
					f" Achieved #{newScoreboard.personalBestRank} rank {withSpecial} on ",
					"[https://osu.troke.id/?u={} {}] achieved rank #1 %s on [https://osu.ppy.sh/b/{} {}] ({})"%(withSpecial,),
					"{} has lost #1 on "
				]

				if s.completed == 3 and not restricted and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and newScoreboard.personalBestRank > oldPersonalBestRank:
					if newScoreboard.personalBestRank == 1 and len(newScoreboard.scores) > 2:
						#woohoo we achieved #1, now we should say to #2 that he sniped!
						userUtils.logUserLog(messages[2].format(newScoreboard.scores[2].playerName), s.fileMd5, newScoreboard.scores[2].playerUserID, s.gameMode, s.scoreID)

					userLogMsg = messages[0]
					userUtils.logUserLog(userLogMsg, s.fileMd5, userID, s.gameMode, s.scoreID)

				# How many PP you got and did you gain any ranks?
				ppGained = newUserStats["pp"] - oldUserStats["pp"]
				gainedRanks = oldRank - rankInfo["currentRank"]

				# Get info about score if they passed the map (Ranked)
				userStats = userUtils.getUserStats(userID, s.gameMode)
				if s.completed == 3 and not restricted and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and s.pp > 0:
					glob.redis.publish("scores:new_score", json.dumps({
						"gm":s.gameMode,
						"user":{"username":username, "userID": userID, "rank":newUserStats["gameRank"],"oldaccuracy":oldStats["accuracy"],"accuracy":newUserStats["accuracy"], "oldpp":oldStats["pp"],"pp":newUserStats["pp"]},
						"score":{"scoreID": s.scoreID, "mods":s.mods, "accuracy":s.accuracy, "missess":s.cMiss, "combo":s.maxCombo, "pp":s.pp, "rank":newScoreboard.personalBestRank, "ranking":s.rank},
						"beatmap":{"beatmapID": beatmapInfo.beatmapID, "beatmapSetID": beatmapInfo.beatmapSetID, "max_combo":beatmapInfo.maxCombo, "song_name":beatmapInfo.songName}
						}))

				# Send message to #announce if we're rank #1
				if newScoreboard.personalBestRank == 1 and s.completed == 3 and not restricted:
					annmsg = "[{}] [{}/{}u/{} {}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({})".format(
						prefixes[cpi],
						glob.conf.config["server"]["serverurl"],
						"rx/" if UsingRelax else "",
						userID,
						username.encode().decode("ASCII", "ignore"),
						beatmapInfo.beatmapID,
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						gameModes.getGamemodeFull(s.gameMode)
						)
					
					if not(userUtils.InvisibleBoard(userID) & 2):
						params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg})
						requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))

					# Let's send them to Discord too, because we cool :sunglasses:
					# First, let's check what mod does the play have
					ScoreMods = ""
					if s.mods == 0:
						ScoreMods += "NM"
					if s.mods & mods.NOFAIL:
						ScoreMods += "NF"
					if s.mods & mods.EASY:
						ScoreMods += "EM" if userID == 3 else "EZ"
					if s.mods & mods.HIDDEN:
						ScoreMods += "HD"
					if s.mods & mods.HARDROCK:
						ScoreMods += "HR"
					if s.mods & mods.PERFECT:
						ScoreMods += "PF"
					elif s.mods & mods.SUDDENDEATH:
						ScoreMods += "SD"
					if s.mods & mods.NIGHTCORE:
						ScoreMods += "NC"
					elif s.mods & mods.DOUBLETIME:
						ScoreMods += "DT"
					if s.mods & mods.HALFTIME:
						ScoreMods += "HT"
					if s.mods & mods.FLASHLIGHT:
						ScoreMods += "FL"
					if s.mods & mods.SPUNOUT:
						ScoreMods += "SO"
					if s.mods & mods.TOUCHSCREEN:
						ScoreMods += "TD"
					if s.mods & mods.RELAX:
						ScoreMods += "RL" if userID == 3 else "RX"
					if s.mods & mods.RELAX2:
						ScoreMods += "ATP" if userID == 3 else "AP" # i had to ATP because AP stands for "ALL PERFECT" in my brain, thanks SEGAwon.

					# Second, get the webhook link from config
					discordLink = 'rxscore' if UsingRelax else 'score'
					discordMode = prefixes[cpi]
					userLink    = 'rx/u' if UsingRelax else 'u'
					urlweb = glob.conf.config["discord"][discordLink]
					webhook = DiscordWebhook(url=urlweb)
					embed = DiscordEmbed(title='New score Achieved!!', description='[{}] Achieved #1 on mode **{}**, {} +{}!'.format(discordMode, gameModes.getGamemodeFull(s.gameMode), beatmapInfo.songName.encode().decode("ASCII", "ignore"), ScoreMods), color=800080)
					embed.set_author(name='{}'.format(username.encode().decode("ASCII", "ignore")), url='https://osu.troke.id/{}/{}'.format(userLink, userID), icon_url='https://a.troke.id/{}'.format(userID))
					embed.add_embed_field(name='Accuracy: {}%'.format(s.accuracy * 100), value='Combo: {}{}'.format(s.maxCombo, ('/{}'.format(beatmapInfo.maxCombo) if s.gameMode != gameModes.MANIA else '')))
					embed.add_embed_field(name='Total: {:.2f}pp'.format(s.pp), value='Gained: {:+.2f}pp'.format(ppGained))
					embed.add_embed_field(name='Played by: {}'.format(username.encode().decode("ASCII", "ignore")), value="[Go to user's profile]({}/{}/{})".format(glob.conf.config["server"]["serverurl"], userLink, userID))
					embed.set_thumbnail(url='https://b.ppy.sh/thumb/{}.jpg'.format(beatmapInfo.beatmapSetID))
					webhook.add_embed(embed)
					log.info(f"[{discordMode}] Score masuk ke discord bro")
					webhook.execute()

				# Write message to client
				self.write(output)
			else:
				# No ranking panel, send just "ok"
				self.write("ok")

			# Send username change request to bancho if needed
			# (key is deleted bancho-side)
			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_usernpame", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			# Send error pass to notify the user
			# resend the score at regular intervals
			# for users with memy connection
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			# We don't have an active bancho session.
			# Don't ban the user but tell the client to send the score again.
			# Once we are sure that this error doesn't get triggered when it
			# shouldn't (eg: bancho restart), we'll ban users that submit
			# scores without an active bancho session.
			# We only log through schiavo atm (see exceptions.py).
			self.set_status(408)
			self.write("error: pass")
		except:
			# Try except block to avoid more errors
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			# Every other exception returns a 408 error (timeout)
			# This avoids lost scores due to score server crash
			# because the client will send the score again after some time.
			if keepSending:
				self.set_status(408)
