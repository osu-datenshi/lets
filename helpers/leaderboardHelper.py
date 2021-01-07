from common.log import logUtils as log
from common.ripple import scoreUtils
from objects import glob
from common.ripple import userUtils

def getRankInfo(userID, gameMode, relax=False):
	"""
	Get userID's current rank, user above us and pp/score difference

	:param userID: user
	:param gameMode: gameMode number
	:return: {"nextUsername": "", "difference": 0, "currentRank": 0}
	"""
	data = {"nextUsername": "", "difference": 0, "currentRank": 0}
	if relax:
		k = "ripple:leaderboard_relax:{}"
		position = userUtils.getGameRankRx(userID, gameMode) - 1
	else:
		k = "ripple:leaderboard:{}"
		position = userUtils.getGameRank(userID, gameMode) - 1
	k = k.format(scoreUtils.readableGameMode(gameMode))
	log.debug("Our position is {}".format(position))
	if position is not None and position > 0:
		aboveUs = glob.redis.zrevrange(k, position - 1, position)
		log.debug("{} is above us".format(aboveUs))
		if aboveUs is not None and len(aboveUs) > 0 and aboveUs[0].isdigit():
			# Get our rank, next rank username and pp/score difference
			myScore = glob.redis.zscore(k, userID)
			otherScore = glob.redis.zscore(k, aboveUs[0])
			nextUsername = userUtils.getUsername(aboveUs[0])
			if nextUsername is not None and myScore is not None and otherScore is not None:
				data["nextUsername"] = nextUsername
				data["difference"] = int(myScore) - int(otherScore)
	else:
		position = 0

	data["currentRank"] = position + 1
	return data

def update(userID, newScore, gameMode, relax=False):
	"""
	Update gamemode's leaderboard.
	Doesn't do anything if userID is banned/restricted.

	:param userID: user
	:param newScore: new score or pp
	:param gameMode: gameMode number
	"""
	if userUtils.isAllowed(userID):
		log.debug("Updating leaderboard...")
		if relax:
			k = "ripple:leaderboard_relax:{}"
		else:
			k = "ripple:leaderboard:{}"
		k = k.format(scoreUtils.readableGameMode(gameMode))
		glob.redis.zadd(k, str(userID), str(newScore))
	else:
		log.debug("Leaderboard update for user {} skipped (not allowed)".format(userID))

def updateCountry(userID, newScore, gameMode, relax=False):
	"""
	Update gamemode's country leaderboard.
	Doesn't do anything if userID is banned/restricted.

	:param userID: user, country is determined by the user
	:param newScore: new score or pp
	:param gameMode: gameMode number
	:return:
	"""
	if userUtils.isAllowed(userID):
		country = userUtils.getCountry(userID)
		if country is not None and len(country) > 0 and country.lower() != "xx":
			log.debug("Updating {} country leaderboard...".format(country))
			if relax:
				k = "ripple:leaderboard_relax:{}:{}"
			else:
				k = "ripple:leaderboard:{}:{}"
			k = k.format(scoreUtils.readableGameMode(gameMode), country.lower())
			glob.redis.zadd(k, str(userID), str(newScore))
	else:
		log.debug("Country leaderboard update for user {} skipped (not allowed)".format(userID))
