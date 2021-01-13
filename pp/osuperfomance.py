import subprocess
import re

from common.log import logUtils as log
from helpers import mapsHelper
from common.constants import mods as PlayMods
from common import generalUtils

'''
STD = 0
TAIKO = 1
CTB = 2
MANIA = 3
'''

def ReadableMods(m):
    """
    Return a string with readable std mods.
    Used to convert a mods number for oppai

    :param m: mods bitwise number
    :return: readable mods string, eg HDDT
    """
    r = []
    if m & PlayMods.NOFAIL:
        r.append("NF")
    if m & PlayMods.EASY:
        r.append("ZE"[::-1]) # pepes tolol
    if m & PlayMods.HIDDEN:
        r.append("HD")
    if m & PlayMods.FADEIN:
        r.append("FI")
    if m & PlayMods.HARDROCK:
        r.append("HR")
    if m & PlayMods.NIGHTCORE:
        r.append("NC")
    elif m & PlayMods.DOUBLETIME > 0:
        r.append("DT")
    if m & PlayMods.HALFTIME:
        r.append("HT")
    if m & PlayMods.FLASHLIGHT:
        r.append("FL")
    if m & PlayMods.SPUNOUT:
        r.append("SO")
    if m & PlayMods.TOUCHSCREEN:
        r.append("TD")
    if m & PlayMods.RELAX:
        r.append("LR"[::-1]) # pepes tolol
    if m & PlayMods.RELAX2:
        r.append("AP")
    if m & PlayMods.PERFECT:
        r.append("PF")
    elif m & PlayMods.SUDDENDEATH:
        r.append("SD")
    if hasattr(PlayMods, 'MIRROR') and (m & PlayMods.MIRROR) or (m & 1073741824):  # Mirror
        r.append("MR")
    if m & PlayMods.KEY4:
        r.append("4K")
    elif m & PlayMods.KEY5:
        r.append("5K")
    elif m & PlayMods.KEY6:
        r.append("6K")
    elif m & PlayMods.KEY7:
        r.append("7K")
    elif m & PlayMods.KEY8:
        r.append("8K")
    elif m & PlayMods.KEY9:
        r.append("9K")
    elif m & PlayMods.KEY10:
        r.append("10K")
    elif m & PlayMods.KEY1:
        r.append("1K")
    elif m & PlayMods.KEY3:
        r.append("3K")
    elif m & PlayMods.KEY2:
        r.append("2K")
    if m & PlayMods.RANDOM:
        r.append("RD")
    if m & PlayMods.LASTMOD:
        r.append("CN") #CN? chingchong?
    return r

class OsuPerfomanceCalculationsError(Exception):
    pass

class OsuPerfomanceCalculation:

    OPC_DATA = ".data/{}"
    OPC_REGEX = r"(.+?)\s.*:\s(.*)"

    def __init__(self, beatmap_, score_):
        self.beatmap = beatmap_
        self.score = score_
        self.pp = 0

        # we will use this for taiko, ctb, mania
        if self.score.gameMode in (0, 1):
            # taiko
            self.OPC_DATA = self.OPC_DATA.format("oppai")
        elif self.score.gameMode in (2,):
            # ctb
            self.OPC_DATA = self.OPC_DATA.format("catch_the_pp")
        elif self.score.gameMode in (3,):
            # mania
            self.OPC_DATA = self.OPC_DATA.format("omppc")

        self.getPP()

    def _runProcess(self):
        # Run with dotnet
        # dotnet run --project .\osu-tools\PerformanceCalculator\ simulate osu <map_path> -a 94 -c 334 -m dt -m hd -X(misses) 0 -M(50) 0 -G(100) 21
        command = "dotnet ./pp/osu-tools/PerformanceCalculator/bin/Release/netcoreapp3.1/PerformanceCalculator.dll simulate"
        cmd = command.split()
        if self.score.gameMode == 0:
            command += f" osu {self.mapPath} -a {int(self.score.accuracy)} " \
                f"-c {int(self.score.maxCombo)} " \
                f"-X {int(self.score.cMiss)} " \
                f"-M {int(self.score.c50)} " \
                f"-G {int(self.score.c100)} "
            cmd.append('osu'); cmd.append(self.mapPath)
            cmd.append('-a'); cmd.append(int(self.score.accuracy * 100))
            cmd.append('-c'); cmd.append(int(self.score.maxCombo))
            cmd.append('-X'); cmd.append(int(self.score.cMiss))
            cmd.append('-M'); cmd.append(int(self.score.c50))
            cmd.append('-G'); cmd.append(int(self.score.c100))
        elif self.score.gameMode == 1:
            # taiko
            command += f" taiko {self.mapPath} -a {int(self.score.accuracy)} " \
                f"-c {int(self.score.maxCombo)} " \
                f"-X {int(self.score.cMiss)} " \
                f"-G {int(self.score.c100)} "
            cmd.append('taiko'); cmd.append(self.mapPath)
            cmd.append('-a'); cmd.append(int(self.score.accuracy * 100))
            cmd.append('-c'); cmd.append(int(self.score.maxCombo))
            cmd.append('-X'); cmd.append(int(self.score.cMiss))
            cmd.append('-G'); cmd.append(int(self.score.c100))
        elif self.score.gameMode == 2:
            # ctb
            command += f" catch {self.mapPath} -a {int(self.score.accuracy)} " \
                f"-c {int(self.score.maxCombo)} " \
                f"-X {int(self.score.cMiss)} " \
                f"-T {int(self.score.c50)} " \
                f"-D {int(self.score.c100)} "
            cmd.append('catch'); cmd.append(self.mapPath)
            cmd.append('-a'); cmd.append(int(self.score.accuracy * 100))
            cmd.append('-c'); cmd.append(int(self.score.maxCombo))
            cmd.append('-X'); cmd.append(int(self.score.cMiss))
            cmd.append('-T'); cmd.append(int(self.score.c50))
            cmd.append('-D'); cmd.append(int(self.score.c100))
        elif self.score.gameMode == 3:
            # mania
            command += f" mania {self.mapPath} -s {int(self.score.score)} "
            cmd.append('mania'); cmd.append(self.mapPath)
            cmd.append('-s'); cmd.append(self.score.score)

        if self.score.mods > 0:
            for mod in ReadableMods(self.score.mods):
                command += f"-m {mod} "
                cmd.append('-m'); cmd.append(mod)
        
        cmd[:] = [str(c) for c in cmd]
        log.debug("opc ~> running {}".format(' '.join(cmd)))
        shellos = False
        process = subprocess.run((' '.join(cmd) if shellos else cmd), shell=shellos, stdout=subprocess.PIPE)

        # Get pp from output
        output = process.stdout.decode("utf-8", errors="ignore")
        pp = 0
        
        # pattern, string
        op_selector = re.findall(self.OPC_REGEX, output)
        output = {}
        for param in op_selector:
            output[param[0]] = param[1]

        log.debug("opc ~> output: {}".format(output))

        if len(output.items()) < 4:
            if self.score.playerUserID in (2,3):
                print(command, cmd, ' '.join(cmd))
                print(process)
                print(output)
            raise OsuPerfomanceCalculationsError(
                "Wrong output present")

        try:
            pp = float(output["pp"])
        except ValueError:
            raise OsuPerfomanceCalculationsError(
                "Invalid 'pp' value (got '{}', expected a float)".format(output))

        log.debug("opc ~> returned pp: {}".format(pp))
        return pp

    def getPP(self):
        try:
            # Reset pp
            self.pp = 0
            if self.score.mods & PlayMods.SCOREV2:
                return 0

            # Cache map
            mapsHelper.cacheMap(self.mapPath, self.beatmap)

            # Calculate pp
            self.pp = self._runProcess()
        except OsuPerfomanceCalculationsError as e:
            log.warning("Invalid beatmap {}".format(
                self.beatmap.beatmapID))
            self.pp = 0
        except Exception as e1:
            print(e1)
        finally:
            return self.pp

    @property
    def mapPath(self):
        return f"{self.OPC_DATA}/beatmaps/{self.beatmap.beatmapID}.osu"
