import tornado.gen
import tornado.web

from common.web import requestsManager


class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	def asyncGet(self):
		print("404: {}".format(self.request.uri))
		self.write("""
				<html>
					<head>
						<link href="https://i.datenshi.xyz/static/memez.css" media="all" rel="stylesheet">
						<link href="https://goverit.troke.id/uikit.css" media="all" rel="stylesheet">
					</head>
					<body class="uk-flex uk-flex-column uk-flex-middle uk-flex-between uk-light">
					<div></div>
					<div class="uk-flex uk-flex-column uk-flex-middle uk-margin-large-bottom">
					<img src="https://datenshi.xyz/static/logo.png" class="uk-margin-small-bottom" width="300" height="300">
					<div class="uk-h1 uk-text-uppercase uk-margin-remove">DATENSHI</div>
					<div class="uk-h5 uk-text-uppercase uk-margin-remove-bottom">First Indonesian osu! Private Server</div>
					<div class="uk-h5 uk-text-uppercase uk-margin-remove">Enjoy, Come and Join Us</div>
					<div class="uk-h5 uk-text-uppercase uk-margin-remove-bottom"><a href="https://link.troke.id/datenshi" target="_blank" class="uk-text-bold">DISCORD</a></div>
					</div>
					<div></div>
					</body>
				</html>
				""")
