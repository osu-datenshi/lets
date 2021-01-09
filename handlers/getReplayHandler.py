import os
import sys
import traceback

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from objects import glob
from common.sentry import sentry

MODULE_NAME = "get_replay"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for osu-getreplay.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		try:
			# insert ripple unfunny roblox word here. very unfunny
			# Get request ip
			ip = self.getRequestIP()

			# Check arguments
			if not requestsManager.checkArguments(self.request.arguments, ["c", "u", "h"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get arguments
			username = self.get_argument("u")
			password = self.get_argument("h")
			replayID = self.get_argument("c")

			# Login check
			userID = userUtils.getID(username)
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, username, ip)

			# Get user ID
			replayMode = 'NM'
			modeData = {
				'NM': ('', 'VANILLA', 'scores'),
				'RL': ('_relax', 'RELAX', 'scores_relax'),
			}
			userStat = glob.db.fetch('select current_status as c from users_stats where id = %s', [userID])
			if userStat['c'].endswith('on Relax'):
				replayMode = 'RL'
			
			replayData = glob.db.fetch("SELECT s.*, users.username AS uname FROM {} as s LEFT JOIN users ON s.userid = users.id WHERE s.id = %s".format(modeData[replayMode][2]), [replayID])
			
			if replayData is not None:
				fileName = "{}{}/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], modeData[replayMode][0], replayID)
				Play = modeData[replayMode][1]
			else:
				log.warning("Replay {} ({}) doesn't exist".format(replayID, replayMode))
				self.write("")
				return

			# Increment 'replays watched by others' if needed
			if replayData is not None:
				if username != replayData["uname"]:
					userUtils.incrementReplaysWatched(replayData["userid"], replayData["play_mode"])
			# Serve replay

			log.info("[{}] Serving replay_{}.osr".format(Play, replayID))

			if os.path.isfile(fileName):
				with open(fileName, "rb") as f:
					fileContent = f.read()
				self.write(fileContent)
			else:
				log.warning("Replay {} doesn't exist".format(replayID))
				self.write("")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.need2FAException:
			pass
		except exceptions.loginFailedException:
			pass
