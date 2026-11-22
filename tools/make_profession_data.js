// Lager Dragonworld\Modules\ProfessionData.lua fra Wowhead sine profession-guider
// for WoW Forever ("Tried & Tested in Forever", Wowhead sin egen testede rute).
//
// Bruk (fra C:\Apper\Wow addon):
//   node tools\make_profession_data.js <mappe for nedlastinger> [--download]
//
// Med --download hentes guidene og oppskriftslistene på nytt fra Wowhead til
// mappen. Uten leses filene som allerede ligger der. Filene er bare data (JSON),
// de kjøres ikke.

const fs = require("fs");
const path = require("path");

const SKILLS = [171, 164, 333, 202, 165, 197, 185, 129]; // Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring, Cooking, First Aid
const SECONDARY = new Set([185, 129]);
const ICONS = {
  171: "Trade_Alchemy", 164: "Trade_BlackSmithing", 333: "Trade_Engraving", 202: "Trade_Engineering",
  165: "Trade_LeatherWorking", 197: "Trade_Tailoring", 185: "INV_Misc_Food_15", 129: "Spell_Holy_SealOfSacrifice",
};
const BASE = "https://www.wowhead.com/forever/profession-leveling-guides/";

// Merknadene i guidene, oversatt i Locales.lua. Ukjente merknader (etter en
// ny nedlasting) blir stående på engelsk til de får en nøkkel her.
const NOTES = {
  "Keep the Philosopher's Stone: transmutes need it.": "PROF_NOTE_PHILOSOPHER",
  "Taught by special trainers after a short questline: the Odd Child in Westfall (Alliance) or Apothecary Renferrel at the Sepulcher in Silverpine Forest (Horde).": "PROF_NOTE_DISCOLORED",
  "Unconfirmed until checked on a live realm: how a new enchanter gets the first rod. Keep the Runed Copper Rod: every enchant up to 155 needs it. Mote of Magic is sold by enchanting supply vendors.": "PROF_NOTE_FIRST_ROD",
  "Disenchant Uncommon (green) or better items to 20: each one is a skill point. Keep the dust and essences for the next steps. Past 20 the chance drops, and it stops at 60.": "PROF_NOTE_DISENCHANT",
  "Keep the Runed Silver Rod: the enchants from here to 155 need it.": "PROF_NOTE_ROD_SILVER",
  "Keep the Runed Golden Rod: the enchants from here to 200 need it.": "PROF_NOTE_ROD_GOLDEN",
  "Keep the Runed Truesilver Rod: the enchants from here to 290 need it.": "PROF_NOTE_ROD_TRUESILVER",
  "Keep the Runed Arcanite Rod: the last enchants need it.": "PROF_NOTE_ROD_ARCANITE",
  "Craft 60 and Save": "PROF_NOTE_SAVE",
  "Craft 30 and Save": "PROF_NOTE_SAVE",
  "Keep the Arclight Spanner: most later recipes need it as a tool.": "PROF_NOTE_SPANNER",
  "Keep the Gyromatic Micro-Adjustor: goggles and scopes need it as a tool.": "PROF_NOTE_GYRO",
  "Trained by Doctor Gustaf VanHowzen in Theramore (Alliance) or Doctor Gregory Victor in Hammerfall (Horde), as in Classic; unconfirmed until checked on a live realm.": "PROF_NOTE_FA_DOCTOR",
};

// Rank-kravene, slik Wowhead viser dem i planleggeren:
// { lær før skill, krever skill, krever level, hvor }
const GATES_CRAFTING = [[75, 50, 10, "trainer"], [150, 125, 20, "trainer"], [225, 200, 35, "trainer"]];
const GATES_SECONDARY = [[75, 50, 10, "trainer"], [150, 125, 0, "book"], [225, 0, 35, "quest"]];

async function download(dir) {
  fs.mkdirSync(dir, { recursive: true });
  for (const skill of SKILLS) {
    for (const kind of ["catalog", "guides"]) {
      const res = await fetch(`${BASE}${kind}?skill=${skill}`, { headers: { "User-Agent": "Mozilla/5.0" } });
      if (!res.ok) throw new Error(`${kind} ${skill}: HTTP ${res.status}`);
      fs.writeFileSync(path.join(dir, `${kind === "catalog" ? "cat" : "guides"}${skill}.json`), await res.text());
    }
  }
  // Siden har datoen hver guide sist ble oppdatert.
  const res = await fetch(BASE + "alchemy", { headers: { "User-Agent": "Mozilla/5.0" } });
  if (res.ok) fs.writeFileSync(path.join(dir, "page.html"), await res.text());
}

// Lua-tekst for en verdi.
function lua(value) {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
  if (Array.isArray(value)) return "{ " + value.map(lua).join(", ") + " }";
  const parts = [];
  for (const [k, v] of Object.entries(value)) {
    if (v === undefined || v === null || v === false) continue;
    const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : /^\d+$/.test(k) ? "[" + k + "]" : "[" + lua(k) + "]";
    parts.push(key + " = " + lua(v));
  }
  return "{ " + parts.join(", ") + " }";
}

function guideDate(dir) {
  try {
    const html = fs.readFileSync(path.join(dir, "page.html"), "utf8");
    const m = html.match(/id="data.page.wow.levelingGuides"[^>]*>([\s\S]*?)<\/script>/);
    const data = JSON.parse(m[1]);
    const out = {};
    for (const p of data.professions) out[p.id] = (p.updated && p.updated.iso || "").slice(0, 10);
    return out;
  } catch (e) {
    return {};
  }
}

// { navn, kvalitet, type, vendorpris, laget med }. Ting som samles (skinning,
// herbalism ...) får typen "gather" i stedet for "other".
function itemEntry(it) {
  const kind = it.type === "other" && it.gathered ? "gather" : it.type;
  const entry = [it.name, it.quality, kind, it.price || 0];
  if (it.madeBy && it.madeBy.length) entry.push(it.madeBy.join(", "));
  return entry;
}

function build(dir) {
  const load = (f) => JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
  const dates = guideDate(dir);
  const professions = {}, recipes = {}, items = {}, vendors = {}, tools = {};
  const usedItems = new Set();

  for (const skill of SKILLS) {
    const cat = load(`cat${skill}.json`).catalog;
    const guide = load(`guides${skill}.json`).guides.find((g) => g.official);
    if (!guide) throw new Error("no official guide for " + skill);
    const byId = Object.fromEntries(cat.recipes.map((r) => [r.id, r]));
    const name = ({ 171: "Alchemy", 164: "Blacksmithing", 333: "Enchanting", 202: "Engineering", 165: "Leatherworking", 197: "Tailoring", 185: "Cooking", 129: "First Aid" })[skill];

    // Hvem i denne professionen lager hva (laveste skill først).
    const makers = {};
    for (const r of cat.recipes) {
      if (r.creates) (makers[r.creates[0]] ||= []).push(r);
    }
    for (const list of Object.values(makers)) list.sort((a, b) => a.learn - b.learn);

    const wanted = new Set(); // oppskrifter som skal med
    const makes = {};         // [itemID] = oppskriften professionen selv lager den med

    // Mellomprodukter: ting oppskriftslisten kaller "craft" (laget av denne
    // professionen) og som ikke selges hos en vendor. De lages underveis.
    function addRecipe(id) {
      if (wanted.has(id)) return;
      const r = byId[id];
      wanted.add(id);
      for (const [itemID] of r.reagents) {
        const it = cat.items[itemID] || {};
        if (it.type === "craft" && !it.price && makers[itemID] && !makes[itemID]) {
          const maker = makers[itemID][0];
          // Ikke ta med omgjøringer begge veier (A fra B og B fra A).
          const loops = maker.reagents.some(([sub]) => (makers[sub] || []).some((m) => m.reagents.some(([x]) => x === itemID)));
          if (!loops) {
            makes[itemID] = maker.id;
            addRecipe(maker.id);
          }
        }
      }
    }

    const steps = [];
    guide.steps.forEach((st, index) => {
      const step = [st.from, st.to, st.recipe || 0];
      const extra = {};
      let note = (st.note || "").trim();
      if (st.recipe) {
        if (!byId[st.recipe]) throw new Error(`${name}: step ${st.from}-${st.to} recipe ${st.recipe} not in catalog`);
        addRecipe(st.recipe);
        // Brukes det som lages her i et senere steg, si at det skal spares.
        const created = byId[st.recipe].creates && byId[st.recipe].creates[0];
        if (!note && created && guide.steps.slice(index + 1).some((later) => later.recipe && byId[later.recipe] && byId[later.recipe].reagents.some(([i]) => i === created))) {
          note = "PROF_NOTE_SAVE";
        }
      }
      if (note) extra.note = NOTES[note] || (note.startsWith("PROF_NOTE_") ? note : note);
      if (st.text) extra.text = true;
      steps.push(Object.keys(extra).length ? [...step, extra] : step);
    });

    for (const id of wanted) {
      const r = byId[id];
      const entry = [r.name, r.learn, r.colors, r.reagents];
      const named = {};
      if (r.creates) {
        named.creates = r.creates[0];
        const avg = (r.creates[1] + r.creates[2]) / 2;
        if (avg !== 1) named.makes = avg;
      }
      if (r.skillUps && r.skillUps !== 1) named.up = r.skillUps;
      if (r.starter) named.starter = true;
      if (r.trainer) named.trainer = true;
      if (r.cost) named.cost = r.cost;
      if (r.drop) named.drop = true;
      if (r.quest) named.quest = true;
      if (r.vendor && r.vendor.length) {
        named.vendors = r.vendor.map((v) => [v.npc, v.price || 0, v.currency ? v.currency[0] : 0, v.currency ? v.currency[1] : 0, v.limited ? 1 : 0]);
        for (const v of r.vendor) {
          const info = cat.vendors[v.npc];
          if (info) vendors[v.npc] = [info.name, info.side, info.zone];
        }
      }
      if (r.recipeItem) {
        named.recipeItem = r.recipeItem;
        usedItems.add(r.recipeItem);
      }
      if (r.reputation) named.rep = [r.reputation.faction, r.reputation.standing];
      if (r.specialization) named.spec = cat.specializations[r.specialization] || String(r.specialization);
      if (r.tools && r.tools.length) {
        named.tools = r.tools;
        for (const t of r.tools) {
          tools[t] = [cat.tools[t].name, cat.tools[t].items];
          cat.tools[t].items.forEach((i) => usedItems.add(i));
        }
      }
      if (r.focus) named.focus = r.focus;
      recipes[id] = [entry, named];
      r.reagents.forEach(([i]) => usedItems.add(i));
      if (r.creates) usedItems.add(r.creates[0]);
    }

    for (const itemID of usedItems) {
      const it = cat.items[itemID];
      if (it && !items[itemID]) items[itemID] = itemEntry(it);
    }

    professions[skill] = {
      name, icon: "Interface\\Icons\\" + ICONS[skill], secondary: SECONDARY.has(skill),
      guide: guide.name, version: guide.version, updated: dates[skill] || "",
      gates: SECONDARY.has(skill) ? GATES_SECONDARY : GATES_CRAFTING,
      steps, makes,
    };
  }

  // Navn på gjenstander som bare finnes i en annen professions liste
  // (f.eks. oppskriftsgjenstander), hentes fra alle listene.
  for (const skill of SKILLS) {
    const cat = load(`cat${skill}.json`).catalog;
    for (const itemID of usedItems) {
      const it = cat.items[itemID];
      if (it && !items[itemID]) items[itemID] = itemEntry(it);
    }
  }

  return { professions, recipes, items, vendors, tools };
}

function write(data, file) {
  const out = [];
  const today = new Date().toISOString().slice(0, 10);
  out.push("-- Dragonworld - data for the Professions tab");
  out.push("-- Made " + today + " by tools\\make_profession_data.js from Wowhead's guides for WoW Forever");
  out.push("-- (" + BASE + "), the route \"Tried & Tested in Forever\".");
  out.push("-- DO NOT edit by hand: run the script again when Wowhead updates the guides.");
  out.push("--");
  out.push("-- professions[skillLine] = { name, icon, secondary, guide, version, updated,");
  out.push("--     gates = { { learn before skill, needs skill, needs level, \"trainer\"/\"book\"/\"quest\" }, ... },");
  out.push("--     steps = { { from skill, to skill, recipe (spell ID, 0 = text), note = Locales key }, ... },");
  out.push("--     makes = { [itemID] = the recipe the profession makes the intermediate product with } }");
  out.push("-- recipes[spellID] = { name, learned at skill, { orange, yellow, green, gray }, { { itemID, count }, ... },");
  out.push("--     creates = itemID, makes = count per craft (1 if not given), up = skill points per craft,");
  out.push("--     starter/trainer/drop/quest = true, cost = trainer price in copper,");
  out.push("--     vendors = { { npcID, price in copper, currencyID, currency amount, limited stock } },");
  out.push("--     recipeItem = itemID, rep = { faction, level }, spec, tools = { tool keys }, focus = station }");
  out.push("-- items[itemID] = { name, quality, kind, vendor price in copper, made with (professions) }");
  out.push("--     kind: \"vendor\" (bought), \"craft\" (made by the profession), \"prof\" (made by another");
  out.push("--     profession), \"gather\" (gathered, e.g. skinning), \"other\" (drops, farmed or AH)");
  out.push("");
  out.push("local ADDON_NAME, DW = ...");
  out.push("");
  out.push("DW.ProfessionData = {");
  out.push("    generated = " + lua(today) + ",");
  out.push("    professions = {");
  for (const [skill, p] of Object.entries(data.professions)) {
    out.push(`        [${skill}] = {`);
    out.push(`            name = ${lua(p.name)}, icon = ${lua(p.icon)}, secondary = ${lua(p.secondary)},`);
    out.push(`            guide = ${lua(p.guide)}, version = ${p.version}, updated = ${lua(p.updated)},`);
    out.push(`            gates = ${lua(p.gates)},`);
    out.push("            steps = {");
    for (const st of p.steps) {
      const [from, to, recipe, extra] = st;
      const name = recipe ? data.recipes[recipe][0][0] : "(text)";
      out.push(`                { ${from}, ${to}, ${recipe}${extra ? ", " + lua(extra).slice(2, -2) : ""} }, -- ${name}`);
    }
    out.push("            },");
    out.push(`            makes = ${lua(Object.fromEntries(Object.entries(p.makes).map(([k, v]) => [k, v])))},`);
    out.push("        },");
  }
  out.push("    },");
  out.push("    recipes = {");
  for (const id of Object.keys(data.recipes).map(Number).sort((a, b) => a - b)) {
    const [entry, named] = data.recipes[id];
    const rest = lua(named).slice(2, -2);
    out.push(`        [${id}] = { ${entry.map(lua).join(", ")}${rest ? ", " + rest : ""} },`);
  }
  out.push("    },");
  out.push("    items = {");
  for (const id of Object.keys(data.items).map(Number).sort((a, b) => a - b)) {
    out.push(`        [${id}] = ${lua(data.items[id])},`);
  }
  out.push("    },");
  out.push("    vendors = {");
  for (const id of Object.keys(data.vendors).map(Number).sort((a, b) => a - b)) {
    out.push(`        [${id}] = ${lua(data.vendors[id])},`);
  }
  out.push("    },");
  out.push("    tools = {");
  for (const [key, t] of Object.entries(data.tools)) {
    out.push(`        ${key} = ${lua(t)},`);
  }
  out.push("    },");
  out.push("}");
  out.push("");
  fs.writeFileSync(file, out.join("\n"), "utf8");
}

(async () => {
  const dir = process.argv[2];
  if (!dir) {
    console.error("usage: node tools/make_profession_data.js <download folder> [--download]");
    process.exit(1);
  }
  if (process.argv.includes("--download")) await download(dir);
  const data = build(dir);
  const file = path.join(__dirname, "..", "Dragonworld", "Modules", "ProfessionData.lua");
  write(data, file);
  console.log("wrote " + file + ": " + Object.keys(data.recipes).length + " recipes, " + Object.keys(data.items).length + " items");
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
