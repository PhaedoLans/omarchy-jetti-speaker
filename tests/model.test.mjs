// Model.js holds the display logic the panel and bar widget share. It is plain
// JS with no QML types precisely so it can be exercised here.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*/, "");
const Model = await import(
  "data:text/javascript," + encodeURIComponent(
    source + "\nexport { safeParse, clean, roleLabel, nextRole, enabledSpeakers,"
    + " summary, delaySpread, isCalibrated, formatDelay, formatGain,"
    + " bandLabel, bandHint, weaknessNote, suggestionDiffers,"
    + " looksDead, deadNote, gainDb, nextGain, nextDelay, gainIsBoost };")
);

let failures = 0;
let total = 0;
function check(name, cond, detail = "") {
  total++;
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name} ${detail}`); failures++; }
}

// Device names come from vendors and land in bar tooltips; they are not trusted.
check("safeParse survives malformed JSON", Model.safeParse("{not json", null) === null);
check("safeParse survives non-strings", Model.safeParse(undefined, 7) === 7);
check("safeParse refuses absurd input", Model.safeParse("x".repeat(2000000), null) === null);
check("clean strips newlines", Model.clean("a\nb\tc", 40) === "a b c");
check("clean truncates", Model.clean("x".repeat(200), 10).length === 10);

check("role cycles through all four", (() => {
  const seen = new Set(); let r = "stereo";
  for (let i = 0; i < 4; i++) { seen.add(r); r = Model.nextRole(r); }
  return seen.size === 4 && r === "stereo";
})());
check("unknown role resets to the safe default", Model.nextRole("nonsense") === "stereo");
check("role labels are human", Model.roleLabel("left") === "Left only");

const profile = {
  speakers: [
    { key: "a", label: "BT", sink: "s1", enabled: true, gain: 0.5, delayMs: 0,
      measured: { heard: true } },
    { key: "b", label: "Laptop", sink: "s2", enabled: true, gain: 1, delayMs: 233.5 },
    { key: "c", label: "Headset", sink: "s3", enabled: false, gain: 1, delayMs: 0 },
    { key: "d", label: "Ghost", sink: null, enabled: true, gain: 1, delayMs: 0 },
  ],
};

check("only enabled speakers with a sink count",
  Model.enabledSpeakers(profile).map((s) => s.key).join(",") === "a,b");
check("delay spread measures the alignment range",
  Model.delaySpread(profile) === 234, Model.delaySpread(profile));
check("a lone speaker has no spread",
  Model.delaySpread({ speakers: [profile.speakers[0]] }) === 0);
check("calibration is detected", Model.isCalibrated(profile) === true);
check("no measurement means not calibrated",
  Model.isCalibrated({ speakers: [profile.speakers[1]] }) === false);

check("summary reports off when stopped",
  Model.summary({ state: "stopped" }, profile) === "Jetti Speaker is off");
check("summary names the speakers when running",
  Model.summary({ state: "running", speakerCount: 2 }, profile) === "2 speakers: BT, Laptop");
check("summary handles a missing profile",
  typeof Model.summary({ state: "running", speakerCount: 1 }, null) === "string");

check("delay formatting is precise when small", Model.formatDelay(3.25) === "3.3 ms");
check("delay formatting drops noise when large", Model.formatDelay(233.5) === "234 ms");
check("gain renders as a percentage", Model.formatGain(0.25) === "25%");
check("gain survives nonsense", Model.formatGain(undefined) === "100%");

check("band labels are human", Model.bandLabel("tweeter") === "Tweeter");
check("an unknown band falls back to primary", Model.bandLabel("wobble") === "Primary");
check("band hint names the crossover",
  Model.bandHint("tweeter", 1000) === "highs only, above 1000 Hz");
check("primary hint mentions bass", /bass/.test(Model.bandHint("primary", 800)));

const weak = { band: "primary", measured: { heard: true, bassToMidDb: -23.3,
  weakness: 23.8, suggestedBand: "tweeter" } };
const strong = { band: "primary", measured: { heard: true, bassToMidDb: 0.5,
  weakness: 0, suggestedBand: "primary" } };
check("a weak speaker is described as tweeter material",
  /tweeter/.test(Model.weaknessNote(weak)));
check("a strong speaker is described as primary material",
  /primary/.test(Model.weaknessNote(strong)));
check("an unmeasured speaker gets no claim", Model.weaknessNote({ band: "primary" }) === "");
check("a differing suggestion is flagged", Model.suggestionDiffers(weak) === true);
check("a matching suggestion is not flagged", Model.suggestionDiffers(strong) === false);

// An output that measures silent repeatedly is probably a socket with nothing
// behind it, not a speaker needing more volume.
check("one silent run is not enough to condemn an output",
  Model.looksDead({ silentRuns: 1 }) === false);
check("two silent runs flags it", Model.looksDead({ silentRuns: 2 }) === true);
check("a speaker with no history is not flagged", Model.looksDead({}) === false);
check("the note says how many times", /3 times/.test(Model.deadNote({ silentRuns: 3 })));
check("no note before the threshold", Model.deadNote({ silentRuns: 1 }) === "");

console.log(`\n${total - failures}/${total} model checks passed`);
process.exit(failures ? 1 : 0);
