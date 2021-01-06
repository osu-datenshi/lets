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
    if m & PlayMods.NOFAIL > 0:
        r.append("NF")
    if m & PlayMods.EASY > 0:
        r.append("EZ")
    if m & PlayMods.HIDDEN > 0:
        r.append("HD")
    if m & PlayMods.FADEIN > 0:
        r.append("FI")
    if m & PlayMods.HARDROCK > 0:
        r.append("HR")
    if m & PlayMods.NIGHTCORE:
        r.append("NC")
    if (not "NC" in r) and (m & PlayMods.DOUBLETIME > 0):
        r.append("DT")
    if m & PlayMods.HALFTIME > 0:
        r.append("HT")
    if m & PlayMods.FLASHLIGHT > 0:
        r.append("FL")
    if m & PlayMods.SPUNOUT > 0:
        r.append("SO")
    if m & PlayMods.TOUCHSCREEN > 0:
        r.append("TD")
    if m & PlayMods.RELAX > 0:
        r.append("RX")
    if m & PlayMods.RELAX2 > 0:
        r.append("AP")
    if m & PlayMods.PERFECT > 0:
        r.append("PF")
    if (not "PF" in r) and (m & PlayMods.SUDDENDEATH > 0):
        r.append("SD")
    if m & 1073741824 > 0:  # Mirror
        r.append("MR")
    if m & PlayMods.KEY4 > 0:
        r.append("4K")
    if m & PlayMods.KEY5 > 0:
        r.append("5K")
    if m & PlayMods.KEY6 > 0:
        r.append("6K")
    if m & PlayMods.KEY7 > 0:
        r.append("7K")
    if m & PlayMods.KEY8 > 0:
        r.append("8K")
    if m & PlayMods.RANDOM > 0:
        r.append("RD")
    if m & PlayMods.LASTMOD > 0:
        r.append("CN")
    if m & PlayMods.KEY9 > 0:
        r.append("9K")
    if m & PlayMods.KEY10 > 0:
        r.append("10K")
    if m & PlayMods.KEY1 > 0:
        r.append("1K")
    if m & PlayMods.KEY3 > 0:
        r.append("3K")
    if m & PlayMods.KEY2 > 0:
        r.append("2K")
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
        if self.score.gameMode == 1:
            # taiko
            self.OPC_DATA = self.OPC_DATA.format("oppai")
        elif self.score.gameMode == 2:
            # ctb
            self.OPC_DATA = self.OPC_DATA.format("catch_the_pp")
        elif self.score.gameMode == 3:
            # mania
            self.OPC_DATA = self.OPC_DATA.format("omppc")

        self.getPP()

    def _runProcess(self):
        # Run with dotnet
        # dotnet run --project .\osu-tools\PerformanceCalculator\ simulate osu <map_path> -a 94 -c 334 -m dt -m hd -X(misses) 0 -M(50) 0 -G(100) 21
        command = "dotnet ./pp/osu-tools/PerformanceCalculator/bin/Release/netcoreapp3.1/PerformanceCalculator.dll simulate"
        if self.score.gameMode == 1:
            # taiko
            command += f" taiko {self.mapPath} -a {int(self.score.accuracy)} " \
                f"-c {int(self.score.maxCombo)} " \
                f"-X {int(self.score.cMiss)} " \
                f"-G {int(self.score.c100)} "
        elif self.score.gameMode == 2:
            # ctb        
            command += f" catch {self.mapPath} -a {int(self.score.accuracy)} " \
                f"-c {int(self.score.maxCombo)} " \
                f"-X {int(self.score.cMiss)} " \
                f"-T {int(self.score.c50)} " \
                f"-D {int(self.score.c100)} " 
        elif self.score.gameMode == 3:
            # mania
            command += f" mania {self.mapPath} -s {int(self.score.score)} "

        if self.score.mods > 0:
            for mod in ReadableMods(self.score.mods):
                command += f"-m {mod} "

        log.debug("opc ~> running {}".format(command))
        process = subprocess.run(
            command, shell=True, stdout=subprocess.PIPE)

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
            if self.score.mods & PlayMods.SCOREV2 > 0:
                return 0

            # Cache map
            mapsHelper.cacheMap(self.mapPath, self.beatmap)

            # Calculate pp
            self.pp = self._runProcess()
        except OsuPerfomanceCalculationsError:
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
