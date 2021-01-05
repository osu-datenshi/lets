from common.constants import gameModes
from pp import rippoppai
from pp import relaxoppai
from pp import osuperfomanc

PP_CALCULATORS = {
    gameModes.STD: rippoppai.oppai,
    gameModes.TAIKO: osuperfomance.OsuPerfomanceCalculation,
    gameModes.CTB: osuperfomance.OsuPerfomanceCalculation,
    gameModes.MANIA: osuperfomance.OsuPerfomanceCalculation
}

PP_RELAX_CALCULATORS = {
    gameModes.STD: relaxoppai.oppai
}