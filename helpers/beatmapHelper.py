import time
import datetime

from common.log import logUtils as log
from common.ripple import userUtils
from constants import rankedStatuses
from helpers import osuapiHelper
from objects import glob
from discord_webhook import DiscordWebhook, DiscordEmbed

QUALIFIED_DAYS = 3
GRAVEYARD_DAYS = 28

def _wrapper_():
    """
    Beatmap Helper Wrapper
    
    To get short explanation, this will have two parts.
    - Criteria system, which degrades or checks map automatically.
    - Autorank system, which promotes map automatically.
    """
    """ CRITERIA SYSTEM """
    def getAllCriteria():
        return glob.db.fetchAll('select * from beatmaps_criteria_control order by priority desc, criteria_id asc');
    def getMatchingCriteria(beatmap):
        criteriaIDs = []
        mapKey = {
            'beatmapset_id': 'beatmapSetID',
            'beatmap_id': 'beatmapID',
            'creator_id': 'creatorID',
            'ranked': 'rankedStatus'
        }
        for criteria in getAllCriteria():
            # SKIP IF ALL CRITERIA IS NULL
            checkable = dict((k, criteria[k]) for k in mapKey)
            if not checkable:
                continue
            # CHECK ALL CRITERIONS HERE
            if not all(checkable[k] == getattr(beatmap,mapKey[k]) for k in mapKey if k in checkable):
                continue
            criteriaIDs.append(criteria['criteria_id'])
            if criteria['stop_on_hit']:
                break
        return criteriaIDs
    def getCriteriaAction(criteriaID):
        return glob.db.fetchAll('select type, int_value as iv, str_value as sv from beatmaps_criteria_actions where criteria_id = %s',[criteriaID])
    
    def criteria__0001RankStatus(beatmap,iv,sv):
        if beatmap.rankedStatusFrozen:
            return
        if beatmap.rankStatus == iv:
            return
        beatmap.rankedStatus = iv
    def criteria__0002RankFreeze(beatmap,iv,sv):
        if beatmap.rankedStatusFrozen == iv:
            return
        if bool(beatmap.rankedStatusFrozen) == bool(iv):
            return
        beatmap.rankedStatusFrozen = iv
    def criteria__0003MapDisplay(beatmap,iv,sv):
        if beatmap.displayTitle == sv:
            return
        beatmap.displayTitle = sv
    criteriaActions = {}
    # Nene超進化! Super Hyper Ultra Ultimate Deluxe Perfect Amazing Shining God 流派東方不敗 Master Freedom Justice Ginga Victory Prime Strong Cute Beautiful Wonderful Champion Galaxy Baby 最高 勇者王 天元突破 無限 無敵 無双 NENEMAXMAXMAXSTORONG NENECHI!
    criteriaActions[0] = lambda bm, iv, sv: None
    criteriaActions[1] = criteria__0001RankStatus
    criteriaActions[2] = criteria__0002RankFreeze
    criteriaActions[3] = criteria__0003MapDisplay
    def criteriaControl(beatmap):
        """
        Criteria Control
          Checks if the beatmap have matching criteria.
          If any, get all available actions.
          For each registered action type, perform it sequential.
          
          NOTE: Custom Beatmaps ARE EXEMPT from criteria control system.
        """
        for cid in getMatchingCriteria(beatmap):
            for act in getCriteriaAction(cid):
                if act['type'] in criteriaActions:
                    criteriaActions[act['type']](beatmap,act['iv'],act['sv'])
    
    """ AUTORANK SYSTEM """
    def autorankQueryWrapper(field, table, key, value):
        r = glob.db.fetch("SELECT {field} as f FROM {table} WHERE {key} = %s".format(field=field,table=table,key=key),[value])
        if r is None:
            return False
        return bool(r['f'])
    def autorankActive(banchoID):
        return autorankQueryWrapper('active','autorank_users','bancho_id', banchoID)
    def autorankUserID(banchoID):
        r = glob.db.fetch("SELECT datenshi_id as user_id FROM autorank_users WHERE bancho_id = %s",[value])
        if r is None:
            return None
        return r['user_id']
    def autorankFlagOK(beatmapID):
        return autorankQueryWrapper('flag_valid','autorank_flags','beatmap_id', beatmapID)
    def autorankFlagForLove(beatmapID):
        return autorankQueryWrapper('flag_lovable','autorank_flags','beatmap_id', beatmapID)
    def autorankAnnounce(beatmap):
        if beatmap.rankedStatus >= 0:
            status = 'disqualified update ranked approved qualified loved'.split()[beatmap.rankedStatus]
        else:
            status = 'void'
        msg = "{} - {} [{}] has been auto-{}".format(beatmap.artist,beatmap.title,beatmap.difficultyName, status)
        webhook = DiscordWebhook(url=glob.conf.config["discord"]["ranked-map"])
        embed = DiscordEmbed(description='{}\nDownload : https://osu.ppy.sh/s/{}'.format(msg, beatmap.beatmapSetID), color=242424)
        embed.set_thumbnail(url='https://b.ppy.sh/thumb/{}.jpg'.format(str(beatmap.beatmapSetID)))
        userID = autorankUserID(beatmap.creatorID)
        if userID:
            username = userUtils.getUsername(userID)
            embed.set_author(name='{}'.format(username), url='https://osu.troke.id/u/{}'.format(str(userID)), icon_url='https://a.troke.id/{}'.format(str(userID)))
        embed.set_footer(text='This map was auto-{} from in-game'.format(status))
        webhook.add_embed(embed)
        webhook.execute()
    def autorankCheck(beatmap):
        # No autorank check for frozen maps
        if beatmap.rankedStatusFrozen not in (0,3):
            return
        # No autorank check for already ranked beatmap
        # Only handle this if the map is ranked by autorank.
        if beatmap.rankedStatusFrozen != 3 and beatmap.rankedStatus >= 2:
            return
        # Only check if the mapper flag is active
        if not autorankActive(beatmap.creatorID):
            return
        # Only check if the map is autorankable.
        if not autorankFlagOK(beatmap.beatmapID):
            return
        # Not checking maps with non updated date.
        log.info(f"Checking {beatmap.songName} for autorank eligiblity.")
        obtainDateTime  = lambda t: datetime.datetime.strptime(t, "%Y-%m-%d %H:%M:%S")
        obtainUnixClock = lambda t: int(time.mktime(t.timetuple()))
        if beatmap.updateDate == 0:
            log.info(f"Updating {beatmap.fileMD5} data")
            data = osuapiHelper.osuApiRequest('get_beatmaps','h={}'.format(beatmap.fileMD5))
            if not data:
                return
            dateTouch   = obtainDateTime(data['last_update'])
            beatmap.updateDate = obtainUnixClock(dateTouch)
        else:
            dateTouch   = datetime.datetime.fromtimestamp(beatmap.updateDate)
        
        dateNow     = datetime.datetime.today()
        dateQualify = dateTouch + datetime.timedelta(days=GRAVEYARD_DAYS - QUALIFIED_DAYS)
        dateRanked  = dateTouch + datetime.timedelta(days=GRAVEYARD_DAYS)
        forLove     = autorankFlagForLove(beatmap.beatmapID)
        rankStatus  = beatmap.rankedStatus
        needWipe    = False
        if dateNow >= dateRanked:
            needWipe = rankStatus == rankedStatuses.QUALIFIED
            if forLove:
                log.info(f"Considering {beatmap.fileMD5} to be loved")
                beatmap.rankedStatus = rankedStatuses.LOVED
            else:
                log.info(f"Considering {beatmap.fileMD5} on ranking")
                beatmap.rankedStatus = rankedStatuses.RANKED
            beatmap.rankedStatusFrozen = 3
        elif dateNow >= dateQualify and not forLove:
            log.info(f"Considering {beatmap.fileMD5} for qualified")
            beatmap.rankedStatus = rankedStatuses.QUALIFIED
            beatmap.rankedStatusFrozen = 3
        else:
            needWipe = rankStatus >= rankedStatuses.RANKED
            beatmap.rankedStatus = rankedStatuses.PENDING
            beatmap.rankedStatusFrozen = 0
        if rankStatus != beatmap.rankedStatus:
            autorankAnnounce(beatmap)
        if needWipe:
            log.info(f"Wiping {beatmap.fileMD5} leaderboard")
            beatmap.clearLeaderboard()
            pass
    
    whitelistFunList = [criteriaControl,autorankCheck]
    whitelistFun = {}
    for f in whitelistFunList:
        whitelistFun[f.__name__] = f
    globals().update(whitelistFun)

_wrapper_()
del _wrapper_
