import tornado.gen
import tornado.web

from common.web import requestsManager
from constants import exceptions
from helpers import replayHelper
from common.sentry import sentry

MODULE_NAME = "get_full_replay"

class baseHandler(requestsManager.asyncRequestHandler):
	"""
	Handler for /replay/
	"""
	rl = False
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self, replayID):
		try:
			fullReplay = replayHelper.buildFullReplay(scoreID=replayID, relax=type(self).rl)
			fileName = replayHelper.returnReplayFileName(scoreID=replayID, relax=type(self).rl)

			self.write(fullReplay)
			self.add_header("Content-type", "application/octet-stream")
			self.set_header("Content-length", len(fullReplay))
			self.set_header("Content-Description", "File Transfer")
			self.set_header("Content-Disposition", "attachment; filename=\"{}.osr\"".format(fileName))
		except (exceptions.fileNotFoundException, exceptions.scoreNotFoundError):
			self.write("Replay not found")
		pass

class standardHandler(baseHandler):
	pass
class relaxHandler(baseHandler):
	rl = True
