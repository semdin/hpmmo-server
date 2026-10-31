extends RefCounted

## The Credits page of the Settings window: whose work the game is built from.
## CC BY 4.0 (NVIDIA SimReady) and MIT (Godot, Terrain3D) ask for this notice
## where players can read it; the OFL fonts and the CC0 sources are thanked too.
## Ends with Godot's own licence and its third-party notices
## (Engine.get_copyright_info / get_license_info). File-level provenance:
## assets/ASSET_CREDITS.md.

## Entries: name, by, licence, url, what (the only translated field - each
## `what` sits on its own line marked for the catalogue).
const SECTIONS := [
	{
		"title": "Licensed assets",  # i18n
		"entries": [
			{
				"name": "NVIDIA SimReady Assets", "by": "© NVIDIA Corporation",
				"licence": "CC BY 4.0", "url": "https://huggingface.co/datasets/nvidia/simready-assets",
				"licence_url": "https://creativecommons.org/licenses/by/4.0/",
				"what": "Food, tableware and kitchen tools on the castle tables. Changed for this game: simplified, re-textured and arranged into table settings.",  # i18n
			},
			{
				"name": "Terrain3D", "by": "© 2023-2026 Cory Petkovsek, Roope Palmroos and Contributors",
				"licence": "MIT", "url": "https://github.com/TokisanGames/Terrain3D",
				"what": "Terrain of the castle grounds",  # i18n
			},
			{
				"name": "Godot Engine", "by": "© 2014-present Godot Engine contributors, © 2007-2014 Juan Linietsky, Ariel Manzur",
				"licence": "MIT", "url": "https://godotengine.org",
				"what": "Game engine. Its licence and third-party notices are at the end of this page.",  # i18n
			},
		],
	},
	{
		"title": "Fonts",  # i18n
		"entries": [
			{
				"name": "Cinzel, Cinzel Decorative", "by": "The Cinzel Project Authors, Natanael Gama",
				"licence": "SIL OFL 1.1", "url": "https://github.com/NDISCOVER/Cinzel",
				"what": "Titles",  # i18n
			},
			{
				"name": "Alegreya Sans", "by": "The Alegreya Sans Project Authors (Huerta Tipográfica)",
				"licence": "SIL OFL 1.1", "url": "https://github.com/huertatipografica/Alegreya-Sans",
				"what": "Body text",  # i18n
			},
			{
				"name": "Marcellus", "by": "Brian J. Bonislawsky, Astigmatic",
				"licence": "SIL OFL 1.1", "url": "https://fonts.google.com/specimen/Marcellus",
				"what": "Interface lettering",  # i18n
			},
			{
				"name": "Philosopher", "by": "The Philosopher Project Authors",
				"licence": "SIL OFL 1.1", "url": "https://github.com/alexeiva/philosopher",
				"what": "Interface lettering",  # i18n
			},
		],
	},
	{
		"title": "Free assets (CC0)",  # i18n
		"entries": [
			{
				"name": "Poly Haven", "by": "", "licence": "CC0 1.0", "url": "https://polyhaven.com",
				"what": "Stone, wood, roof and cave textures; trees, ferns and rocks",  # i18n
			},
			{
				"name": "ambientCG", "by": "Lennart Demes", "licence": "CC0 1.0", "url": "https://ambientcg.com",
				"what": "Grass and rock textures of the terrain",  # i18n
			},
			{
				"name": "Universal Animation Library", "by": "Quaternius", "licence": "CC0 1.0",
				"url": "https://quaternius.com",
				"what": "Character animations",  # i18n
			},
			{
				"name": "KayKit Adventurers", "by": "Kay Lousberg", "licence": "CC0 1.0",
				"url": "https://kaylousberg.com",
				"what": "The robed wizard",  # i18n
			},
			{
				"name": "Particle Pack", "by": "Kenney", "licence": "CC0 1.0", "url": "https://kenney.nl",
				"what": "Flame and spark sprites",  # i18n
			},
		],
	},
	{
		"title": "Made with",  # i18n
		"entries": [
			{
				"name": "Blender", "by": "Blender Foundation", "licence": "", "url": "https://www.blender.org",
				"what": "Modelling, rigging and baking",  # i18n
			},
			{
				"name": "Tencent Hunyuan3D, Meshy", "by": "", "licence": "", "url": "",
				"what": "Generated 3D models of characters, creatures and items",  # i18n
			},
			{
				"name": "OpenAI, Google Gemini, Alibaba Wan (fal.ai)", "by": "", "licence": "", "url": "",
				"what": "Generated concept art, icons and spell effects",  # i18n
			},
			{
				"name": "Hunyuan Motion (fal.ai)", "by": "", "licence": "", "url": "",
				"what": "Generated spell-casting motion",  # i18n
			},
			{
				"name": "ElevenLabs", "by": "", "licence": "", "url": "https://elevenlabs.io",
				"what": "Generated sound effects and music",  # i18n
			},
		],
	},
]

const NAME_SIZE := 16
const TEXT_SIZE := 14
const NOTICE_SIZE := 12


## A scrolling page with every section, then Godot's licence and notices.
static func build() -> RichTextLabel:
	var page := RichTextLabel.new()
	page.name = "Credits"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.scroll_active = true
	page.selection_enabled = true
	page.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.focus_mode = Control.FOCUS_NONE
	page.add_theme_font_override("normal_font", HudKit.body())
	page.add_theme_font_override("bold_font", HudKit.bold())
	page.add_theme_font_size_override("normal_font_size", TEXT_SIZE)
	page.add_theme_font_size_override("bold_font_size", NAME_SIZE)
	page.add_theme_color_override("default_color", HudKit.TEXT)
	page.meta_clicked.connect(func(meta: Variant): OS.shell_open(String(meta)))
	# Godot's notices are long and plain; building them is cheap, laying them out
	# is not - the page fills when it is first shown.
	page.visibility_changed.connect(func():
		if page.is_visible_in_tree() and page.get_total_character_count() == 0:
			_fill(page))
	return page


static func _fill(page: RichTextLabel) -> void:
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(I18n.t("%s is built on the work of the people and tools below. Thank you.") % UITheme.GAME_TITLE)
	page.pop()
	page.newline()
	for section in SECTIONS:
		_heading(page, I18n.t(String(section["title"])))
		for entry in section["entries"]:
			_entry(page, entry)
	_heading(page, I18n.t("Godot Engine licence"))
	_notice(page, Engine.get_license_text())
	_heading(page, I18n.t("Third-party components of Godot Engine"))
	for component in Engine.get_copyright_info():
		page.push_bold()
		page.add_text(String(component["name"]))
		page.pop()
		page.newline()
		for part in component["parts"]:
			var lines: PackedStringArray = []
			for line in part["copyright"]:
				lines.append("© " + String(line))
			lines.append(String(part["license"]))
			_notice(page, "\n".join(lines))
	_heading(page, I18n.t("Licence texts"))
	var licences: Dictionary = Engine.get_license_info()
	for key in licences:
		page.push_bold()
		page.add_text(String(key))
		page.pop()
		page.newline()
		_notice(page, String(licences[key]))


static func _heading(page: RichTextLabel, text: String) -> void:
	page.newline()
	page.push_font(HudKit.title(), 15)
	page.push_color(HudKit.GOLD)
	page.add_text(I18n.upper(text))
	page.pop()
	page.pop()
	page.newline()


static func _entry(page: RichTextLabel, entry: Dictionary) -> void:
	page.push_bold()
	page.push_color(HudKit.GOLD_HI)
	page.add_text(String(entry["name"]))
	page.pop()
	page.pop()
	var licence := String(entry.get("licence", ""))
	if licence != "":
		page.add_text("  ")
		page.push_color(HudKit.GOLD_LT)
		var licence_url := String(entry.get("licence_url", ""))
		if licence_url != "":
			page.push_meta(licence_url)
		page.add_text(licence)
		if licence_url != "":
			page.pop()
		page.pop()
	page.newline()
	if String(entry.get("by", "")) != "":
		page.push_color(HudKit.TEXT_DIM)
		page.add_text(String(entry["by"]))
		page.pop()
		page.newline()
	page.add_text(I18n.t(String(entry["what"])))
	page.newline()
	var url := String(entry.get("url", ""))
	if url != "":
		page.push_color(HudKit.GOLD_LT)
		page.push_meta(url)
		page.add_text(url)
		page.pop()
		page.pop()
		page.newline()
	page.newline()


static func _notice(page: RichTextLabel, text: String) -> void:
	page.push_font_size(NOTICE_SIZE)
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(text.strip_edges())
	page.pop()
	page.pop()
	page.newline()
	page.newline()
