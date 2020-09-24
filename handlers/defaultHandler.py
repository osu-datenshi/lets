import tornado.gen
import tornado.web

from common.web import requestsManager


class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	def asyncGet(self):
		print("404: {}".format(self.request.uri))
		self.write("""
				<!DOCTYPE html> <head> <meta charset='utf-8'> <meta http-equiv='X-UA-Compatible' content='IE=edge'> <title>DATENSHI</title> <meta name='description' content='DATENSHI BACKEND'> <meta name='viewport' content='width=device-width, initial-scale=1'> <link rel='icon' href='https://i.datenshi.xyz/static/logos/text-white.png'> <style>body{background-color: blueviolet;}.img-container{text-align: center; display: block;}h1, p, a{color: aliceblue; font-family: Arial, Helvetica, sans-serif;}</style> </head><body> <div class='img-container'> <img src='https://datenshi.xyz/static/logo2.png'> <h1>DATENSHI</h1> <p>So you are here? If you do understand exactly what you are doing, you should come work with us <a href='https://github.com/osu-datenshi'>/github</a></p></div></body></html>
				""")
