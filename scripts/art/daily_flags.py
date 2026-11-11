"""48 new original designs for the Flag Shop's daily rotation.

Each entry is (display name, rarity, set, SVG body). The body is what goes
inside flags.svg(): viewBox 0 0 160 120, background rect first. All art is
original; no real flag, emblem or organisation is depicted.
"""


def _bg(c):
    return f'<rect width="160" height="120" fill="{c}"/>'


def _hex(cx, cy, r, fill):
    pts = " ".join(f"{cx + dx * r:.1f} {cy + dy * r:.1f}" for dx, dy in
                   [(0, -1), (.866, -.5), (.866, .5), (0, 1), (-.866, .5), (-.866, -.5)])
    return f'<polygon points="{pts}" fill="{fill}"/>'


def _rot(shape, angles, cx, cy):
    return "".join(f'<g transform="rotate({a} {cx} {cy})">{shape}</g>' for a in angles)


_ANTLER = ('<g fill="none" stroke="#3b2412" stroke-width="6" stroke-linecap="round">'
           '<path d="M70 62C60 46 54 32 52 14"/><path d="M62 46L44 40"/><path d="M57 28L42 22"/><path d="M53 18L60 6"/></g>')
_WING_L = '<path d="M80 60C52 30 20 28 6 34C18 44 16 50 10 56C24 58 26 66 22 74C40 72 56 76 80 72z"/>'
_FLIP = '<g transform="translate(160 0) scale(-1 1)">'
_ARMS = ('<g fill="none" stroke="#f2c230" stroke-width="10" stroke-linecap="round"><path d="M58 64C42 74 28 90 38 104C46 112 58 104 52 98"/>'
         '<path d="M68 70C60 86 60 102 70 110C78 114 82 106 76 102"/><path d="M76 72C80 82 84 92 82 100"/></g>')
_SHIELD = "M24 8H136V62C136 92 106 108 80 118C54 108 24 92 24 62z"

DAILY_NEW = {
    # ---- common (17) ----
    "amber_fox": ("Amber Fox", "common", "daily",
        _bg("#1f6f78") +
        '<path d="M36 18L66 42H94L124 18L134 66L80 108L26 66Z" fill="#f08a24"/>'
        '<path d="M80 108L48 70H112Z" fill="#fbefd8"/><path d="M71 96H89L80 108Z" fill="#2a1a12"/>'
        '<circle cx="62" cy="58" r="5" fill="#2a1a12"/><circle cx="98" cy="58" r="5" fill="#2a1a12"/>'),
    "stone_keep": ("Stone Keep", "common", "daily",
        _bg("#d9c9a3") +
        '<rect x="56" y="40" width="48" height="70" fill="#3b4350"/>'
        '<rect x="56" y="26" width="14" height="16" fill="#3b4350"/><rect x="73" y="26" width="14" height="16" fill="#3b4350"/><rect x="90" y="26" width="14" height="16" fill="#3b4350"/>'
        '<path d="M70 110V92a10 10 0 0 1 20 0V110z" fill="#d9c9a3"/><rect x="76" y="52" width="8" height="16" fill="#d9c9a3"/>'
        '<rect y="106" width="160" height="14" fill="#3b4350"/>'),
    "sand_hourglass": ("Sand Hourglass", "common", "daily",
        _bg("#7a1f2b") +
        '<path d="M50 24H110L84 60L110 96H50L76 60Z" fill="#f3e6c4"/>'
        '<path d="M62 96L80 72L98 96Z" fill="#e7a53a"/>'
        '<rect x="42" y="12" width="76" height="12" rx="3" fill="#f3e6c4"/><rect x="42" y="96" width="76" height="12" rx="3" fill="#f3e6c4"/>'),
    "lone_pine": ("Lone Pine", "common", "daily",
        _bg("#efe6cc") +
        '<g fill="#1f5c3a"><path d="M80 10L106 48H54z"/><path d="M80 30L114 74H46z"/><path d="M80 52L122 100H38z"/></g>'
        '<rect x="73" y="98" width="14" height="16" fill="#6b4a2b"/>'),
    "half_moon": ("Half Moon", "common", "daily",
        _bg("#d9812b") +
        '<path d="M80 18a42 42 0 0 0 0 84z" fill="#5a2d82"/><path d="M80 18a42 42 0 0 1 0 84z" fill="#fff1cf"/>'),
    "twin_chevrons": ("Twin Chevrons", "common", "daily",
        _bg("#1e5a3c") +
        '<g fill="#f2c230"><path d="M16 50L80 10L144 50V74L80 34L16 74z"/><path d="M16 86L80 46L144 86V110L80 70L16 110z"/></g>'),
    "brass_key": ("Brass Key", "common", "daily",
        _bg("#3b2f6b") +
        '<circle cx="50" cy="60" r="22" fill="none" stroke="#f2c230" stroke-width="12"/>'
        '<rect x="70" y="54" width="62" height="12" fill="#f2c230"/><rect x="104" y="66" width="10" height="20" fill="#f2c230"/><rect x="122" y="66" width="10" height="14" fill="#f2c230"/>'),
    "black_diamond": ("Black Diamond", "common", "daily",
        _bg("#e7b83a") +
        '<path d="M80 12L142 60L80 108L18 60z" fill="#3a1c4f"/><path d="M80 38L112 60L80 82L48 60z" fill="#e7b83a"/>'),
    "lone_sail": ("Lone Sail", "common", "daily",
        _bg("#9fd7ee") +
        '<path d="M36 82H124L108 102H52z" fill="#7a4a2b"/><rect x="77" y="18" width="6" height="66" fill="#7a4a2b"/>'
        '<path d="M86 20V78H124z" fill="#ffffff"/><path d="M74 30V78H42z" fill="#ffffff"/>'
        '<rect y="96" width="160" height="24" fill="#1f7aa8"/>'),
    "river_trout": ("River Trout", "common", "daily",
        _bg("#e2644f") +
        '<ellipse cx="68" cy="60" rx="46" ry="26" fill="#17606e"/><path d="M108 60L146 32V88z" fill="#17606e"/>'
        '<path d="M56 38L76 18L92 38z" fill="#17606e"/><path d="M52 66H100" stroke="#f4e9d0" stroke-width="6" stroke-linecap="round"/>'
        '<circle cx="42" cy="54" r="6" fill="#f4e9d0"/>'),
    "summer_sun": ("Summer Sun", "common", "daily",
        _bg("#5a2d82") +
        '<g transform="translate(80 60)" fill="#ffd23f"><circle r="26"/>' +
        _rot('<path d="M-9-34L0-56L9-34z"/>', range(0, 360, 45), 0, 0) + '</g>'),
    "stone_arch": ("Stone Arch", "common", "daily",
        _bg("#b5623a") +
        '<path d="M28 112V58a52 52 0 0 1 104 0V112H106V60a26 26 0 0 0-52 0V112z" fill="#f3e6c4"/>'),
    "signal_pennant": ("Signal Pennant", "common", "daily",
        _bg("#1b7f79") +
        '<rect x="24" y="10" width="8" height="104" fill="#f3e6c4"/><path d="M32 22H142L118 50L142 78H32z" fill="#f08a24"/>'),
    "sea_turtle": ("Sea Turtle", "common", "daily",
        _bg("#e8d28a") +
        '<g fill="#2f7d4a"><circle cx="80" cy="20" r="11"/><ellipse cx="80" cy="64" rx="30" ry="36"/>'
        '<ellipse cx="44" cy="40" rx="16" ry="8" transform="rotate(-30 44 40)"/><ellipse cx="116" cy="40" rx="16" ry="8" transform="rotate(30 116 40)"/>'
        '<ellipse cx="48" cy="90" rx="14" ry="7" transform="rotate(30 48 90)"/><ellipse cx="112" cy="90" rx="14" ry="7" transform="rotate(-30 112 90)"/>'
        '<path d="M72 98L80 114L88 98z"/></g>' +
        "".join(_hex(x, y, 10, "#6fcf8a") for x, y in [(80, 64), (80, 40), (80, 88), (62, 52), (98, 52), (62, 76), (98, 76)])),
    "ringed_planet": ("Ringed Planet", "common", "daily",
        _bg("#d14a6a") +
        '<circle cx="80" cy="60" r="32" fill="#ffd23f"/>'
        '<ellipse cx="80" cy="60" rx="58" ry="14" fill="none" stroke="#fff1cf" stroke-width="8" transform="rotate(-20 80 60)"/>'),
    "spring_leaf": ("Spring Leaf", "common", "daily",
        _bg("#f3ecd2") +
        '<path d="M26 104C26 44 76 16 134 16C138 72 102 112 26 104z" fill="#3f9a4a"/>'
        '<path d="M32 100L112 38" stroke="#f3ecd2" stroke-width="6" stroke-linecap="round"/>'),
    "paper_kite": ("Paper Kite", "common", "daily",
        _bg("#8fd1c4") +
        '<path d="M80 8L114 44L80 88L46 44z" fill="#e2483d"/><path d="M80 8L46 44L80 88z" fill="#a8261e"/>'
        '<path d="M80 88C66 98 94 104 80 116" fill="none" stroke="#a8261e" stroke-width="5" stroke-linecap="round"/>'),

    # ---- rare (17) ----
    "iron_bastion": ("Iron Bastion", "rare", "daily",
        _bg("#6a1f24") +
        '<g fill="#b8bec6"><rect x="28" y="40" width="34" height="70"/><rect x="98" y="40" width="34" height="70"/><rect x="62" y="62" width="36" height="48"/>'
        '<rect x="28" y="28" width="9" height="14"/><rect x="42" y="28" width="9" height="14"/><rect x="55" y="28" width="7" height="14"/>'
        '<rect x="98" y="28" width="7" height="14"/><rect x="109" y="28" width="9" height="14"/><rect x="123" y="28" width="9" height="14"/>'
        '<rect x="64" y="50" width="10" height="14"/><rect x="86" y="50" width="10" height="14"/></g>'
        '<path d="M70 110V90a10 10 0 0 1 20 0V110z" fill="#2a0c10"/><rect x="42" y="56" width="6" height="14" fill="#2a0c10"/><rect x="112" y="56" width="6" height="14" fill="#2a0c10"/>'
        '<rect y="110" width="160" height="10" fill="#d9b44a"/>'),
    "twin_rivers": ("Twin Rivers", "rare", "daily",
        _bg("#3f8a4a") +
        '<g fill="none" stroke-linecap="round"><g stroke="#e8d28a" stroke-width="26"><path d="M28 -4C40 40 72 46 80 70"/><path d="M132 -4C120 40 88 46 80 70"/><path d="M80 70C80 90 70 104 78 124"/></g>'
        '<g stroke="#4fb3e8" stroke-width="14"><path d="M28 -4C40 40 72 46 80 70"/><path d="M132 -4C120 40 88 46 80 70"/><path d="M80 70C80 90 70 104 78 124"/></g></g>'),
    "blue_bulwark": ("Blue Bulwark", "rare", "daily",
        _bg("#e8dcc0") +
        '<path d="M30 12H130V62C130 90 104 106 80 114C56 106 30 90 30 62z" fill="#2b5d8a"/>'
        '<path d="M30 38L80 68L130 38V58L80 88L30 58z" fill="#f2c230"/>'),
    "lunar_cycle": ("Lunar Cycle", "rare", "daily",
        _bg("#2a2438") +
        '<g fill="none" stroke="#f3e6b0" stroke-width="4"><circle cx="28" cy="58" r="22"/><circle cx="80" cy="58" r="22"/></g>'
        '<path d="M28 36A22 22 0 0 0 28 80A12 22 0 0 1 28 36z" fill="#f3e6b0"/>'
        '<path d="M80 36A22 22 0 0 1 80 80z" fill="#f3e6b0"/><circle cx="132" cy="58" r="22" fill="#f3e6b0"/>'
        '<rect x="12" y="96" width="136" height="8" rx="4" fill="#e08a2b"/>'),
    "frost_crystals": ("Frost Crystals", "rare", "daily",
        _bg("#1c4a5e") +
        '<path d="M36 44L52 56V96L36 108L20 96V56z" fill="#7fd0e6"/><path d="M124 54L140 66V98L124 108L108 98V66z" fill="#7fd0e6"/>'
        '<path d="M80 8L106 28V92L80 114L54 92V28z" fill="#e8f6fa"/><path d="M80 8L106 28V92L80 114z" fill="#7fd0e6"/>'),
    "dotted_route": ("Dotted Route", "rare", "daily",
        _bg("#e9d8a6") +
        '<rect x="8" y="8" width="144" height="104" fill="none" stroke="#8a5a2b" stroke-width="6"/>'
        '<path d="M26 88C52 38 82 104 110 52" fill="none" stroke="#c0392b" stroke-width="6" stroke-linecap="round" stroke-dasharray="1 13"/>'
        '<circle cx="26" cy="88" r="9" fill="#2f6f4a"/><circle cx="126" cy="40" r="13" fill="#c0392b"/><circle cx="126" cy="40" r="5" fill="#e9d8a6"/>'),
    "beacon_tower": ("Beacon Tower", "rare", "daily",
        _bg("#3b1f5c") +
        '<path d="M80 34L6 12V56z" fill="#ffd23f" opacity=".8"/><path d="M80 34L154 12V56z" fill="#ffd23f" opacity=".8"/>'
        '<path d="M62 110L70 46H90L98 110z" fill="#f4f4f4"/>'
        '<path d="M67.6 62H92.4L93 76H67z" fill="#c0392b"/><path d="M65.5 88H94.5L95.2 102H64.8z" fill="#c0392b"/>'
        '<rect x="69" y="32" width="22" height="14" fill="#ffd23f"/><path d="M66 32L80 16L94 32z" fill="#c0392b"/>'
        '<rect x="40" y="108" width="80" height="12" fill="#1c0f30"/>'),
    "old_windmill": ("Old Windmill", "rare", "daily",
        _bg("#8fcbe8") +
        '<rect y="98" width="160" height="22" fill="#5aa04a"/>'
        '<path d="M60 104L70 54H90L100 104z" fill="#f0e0b8"/><path d="M66 56L80 40L94 56z" fill="#b5412e"/>'
        '<path d="M72 104V92a8 8 0 0 1 16 0V104z" fill="#7a4a2b"/>'
        '<g transform="translate(80 48) rotate(40)" fill="#ffffff"><rect x="-5" y="-42" width="10" height="42"/><rect x="-5" y="0" width="10" height="42"/><rect x="-42" y="-5" width="42" height="10"/><rect x="0" y="-5" width="42" height="10"/></g>'
        '<circle cx="80" cy="48" r="7" fill="#7a4a2b"/>'),
    "swift_wings": ("Swift Wings", "rare", "daily",
        _bg("#f2c230") +
        '<path d="M0 120V86L160 108V120z" fill="#e0472f"/>'
        '<path d="M16 46C48 16 70 26 80 60C90 26 112 16 144 46C114 42 98 54 80 84C62 54 46 42 16 46z" fill="#2a1f4a"/>'),
    "bear_track": ("Bear Track", "rare", "daily",
        _bg("#2d5a3d") + '<path d="M0 0H64L0 74z" fill="#234a31"/>'
        '<g fill="#e8d8b0"><ellipse cx="80" cy="80" rx="30" ry="24"/><ellipse cx="40" cy="52" rx="10" ry="14" transform="rotate(-22 40 52)"/>'
        '<ellipse cx="62" cy="32" rx="10" ry="14" transform="rotate(-6 62 32)"/><ellipse cx="98" cy="32" rx="10" ry="14" transform="rotate(6 98 32)"/>'
        '<ellipse cx="120" cy="52" rx="10" ry="14" transform="rotate(22 120 52)"/></g>'),
    "golden_spiral": ("Golden Spiral", "rare", "daily",
        _bg("#7a2f1f") +
        '<g transform="translate(80 60) scale(1.5) translate(-80 -60)"><path d="M80 60A5 5 0 0 1 90 60A10 10 0 0 1 70 60A15 15 0 0 1 100 60A20 20 0 0 1 60 60A25 25 0 0 1 110 60A30 30 0 0 1 50 60" fill="none" stroke="#f2c230" stroke-width="5" stroke-linecap="round"/></g>'),
    "stone_bridge": ("Stone Bridge", "rare", "daily",
        _bg("#cfe8f0") +
        '<rect y="48" width="160" height="16" fill="#6f737c"/><rect y="64" width="160" height="32" fill="#8d8f96"/>'
        '<rect y="90" width="160" height="30" fill="#3a86b8"/>'
        '<g fill="#3a86b8"><path d="M16 92a20 22 0 0 1 40 0z"/><path d="M64 92a20 22 0 0 1 40 0z"/><path d="M112 92a20 22 0 0 1 40 0z"/></g>'
        ''),
    "dune_camp": ("Dune Camp", "rare", "daily",
        _bg("#f0a04b") +
        '<circle cx="128" cy="32" r="14" fill="#fff1d6"/><path d="M0 98C40 72 80 102 160 80V120H0z" fill="#b5532a"/>'
        '<path d="M52 100L82 40L112 100z" fill="#fff1d6"/><path d="M75 100L82 68L89 100z" fill="#6b2d1a"/>'),
    "drawn_blade": ("Drawn Blade", "rare", "daily",
        _bg("#3d4a5c") +
        '<path d="M0 120V70L50 120z" fill="#8a1f2e"/><path d="M160 0V50L110 0z" fill="#8a1f2e"/>'
        '<g transform="rotate(45 80 60)"><path d="M80 4L90 26V78H70V26z" fill="#dfe5ec"/><rect x="50" y="78" width="60" height="10" rx="3" fill="#f2c230"/>'
        '<rect x="74" y="88" width="12" height="20" fill="#7a4a2b"/><circle cx="80" cy="113" r="7" fill="#f2c230"/></g>'),
    "arrow_volley": ("Arrow Volley", "rare", "daily",
        _bg("#d9c9a3") +
        _rot('<rect x="77.5" y="28" width="5" height="76" fill="#5b3a1f"/><path d="M80 6L91 32H69z" fill="#2b2b2b"/><path d="M80 94L67 112L80 106L93 112z" fill="#c0392b"/>', (-20, 0, 20), 80, 116)),
    "honey_hex": ("Honey Hex", "rare", "daily",
        _bg("#3b2412") +
        _hex(80, 60, 18, "#ffd23f") + "".join(_hex(x, y, 18, "#e8941a") for x, y in
            [(116, 60), (44, 60), (98, 91), (62, 91), (98, 29), (62, 29)])),
    "palm_isle": ("Palm Isle", "rare", "daily",
        _bg("#ffcf6b") +
        '<rect y="86" width="160" height="34" fill="#1fa3b8"/><ellipse cx="80" cy="90" rx="52" ry="14" fill="#e8c47a"/>'
        '<path d="M78 90C72 68 82 50 92 36" fill="none" stroke="#7a4a2b" stroke-width="9" stroke-linecap="round"/>'
        '<g fill="#2f9a4a"><path d="M92 36C72 20 52 28 42 46C60 36 76 38 92 36z"/><path d="M92 36C102 16 126 16 138 32C122 28 108 32 92 36z"/>'
        '<path d="M92 36C82 14 92 6 106 4C100 16 98 28 92 36z"/><path d="M92 36C74 40 64 54 66 68C78 54 86 46 92 36z"/></g>'),

    # ---- epic (9) ----
    "tall_galleon": ("Tall Galleon", "epic", "daily",
        _bg("#0f4c5c") +
        '<path d="M28 78H132L114 104H46z" fill="#8a4b2a"/><rect x="36" y="86" width="88" height="6" fill="#f2c230"/>'
        '<rect x="77" y="10" width="6" height="70" fill="#5b3a1f"/><path d="M85 14Q126 34 126 72H85z" fill="#f8f0da"/><path d="M75 22Q40 38 40 72H75z" fill="#f8f0da"/>'
        '<path d="M83 8H106L98 14L106 20H83z" fill="#e2483d"/>'
        '<path d="M0 100Q20 92 40 100T80 100T120 100T160 100V120H0z" fill="#1f7aa8"/>'),
    "sun_stag": ("Sun Stag", "epic", "daily",
        _bg("#1d4d3a") +
        '<circle cx="80" cy="58" r="42" fill="#f2c230"/><circle cx="80" cy="58" r="42" fill="none" stroke="#fff1cf" stroke-width="5"/>'
        '<path d="M60 52L74 62L56 68z" fill="#3b2412"/><path d="M100 52L86 62L104 68z" fill="#3b2412"/>'
        '<path d="M62 62H98L90 100L80 108L70 100z" fill="#3b2412"/>' + _ANTLER +
        _FLIP + _ANTLER + '</g>'
        '<circle cx="71" cy="76" r="4" fill="#f2c230"/><circle cx="89" cy="76" r="4" fill="#f2c230"/>'),
    "gilded_hourglass": ("Gilded Hourglass", "epic", "daily",
        _bg("#2a2a40") +
        '<circle cx="80" cy="60" r="52" fill="none" stroke="#f2c230" stroke-width="5"/>'
        '<g transform="rotate(-15 80 60)"><path d="M50 22H110L84 60L110 98H50L76 60z" fill="#bfe9f0"/>'
        '<path d="M62.3 40H97.7L85 58H75z" fill="#f08a24"/><rect x="78" y="58" width="4" height="24" fill="#f08a24"/><path d="M62 98H98L80 76z" fill="#f08a24"/>'
        '<g fill="#f2c230"><rect x="40" y="10" width="80" height="12" rx="3"/><rect x="40" y="98" width="80" height="12" rx="3"/><rect x="44" y="22" width="7" height="76"/><rect x="109" y="22" width="7" height="76"/></g></g>'),
    "nova_burst": ("Nova Burst", "epic", "daily",
        _bg("#1a1033") +
        '<circle cx="80" cy="60" r="54" fill="none" stroke="#ff4f81" stroke-width="5"/>'
        '<g transform="translate(80 60)"><g fill="#f08a24">' + _rot('<path d="M0-54L10-10H-10z"/>', (0, 90, 180, 270), 0, 0) + '</g>'
        '<g fill="#ffd23f">' + _rot('<path d="M0-36L7-8H-7z"/>', (45, 135, 225, 315), 0, 0) + '</g>'
        '<circle r="18" fill="#ffd23f"/><circle r="9" fill="#ffffff"/></g>'),
    "winged_key": ("Winged Key", "epic", "daily",
        _bg("#164f4a") +
        '<g fill="#f4f1e6">' + _WING_L + '</g>' + _FLIP + '<g fill="#f4f1e6">' + _WING_L + '</g></g>'
        '<circle cx="80" cy="32" r="14" fill="none" stroke="#f2c230" stroke-width="9"/><rect x="76" y="46" width="8" height="58" fill="#f2c230"/>'
        '<rect x="84" y="84" width="16" height="9" fill="#f2c230"/><rect x="84" y="97" width="11" height="9" fill="#f2c230"/>'),
    "gilded_aegis": ("Gilded Aegis", "epic", "daily",
        _bg("#1c3f6e") +
        f'<path d="{_SHIELD}" fill="#f2c230"/>'
        f'<g transform="translate(11 8) scale(.86)"><path d="{_SHIELD}" fill="#7a1f2b"/></g>'
        '<path d="M42 38L80 64L118 38V56L80 82L42 56z" fill="#f4f1e6"/><path d="M80 88L90 98L80 108L70 98z" fill="#f2c230"/>'
        '<g fill="#f2c230"><circle cx="40" cy="26" r="5"/><circle cx="120" cy="26" r="5"/></g>'),
    "aurora_veil": ("Aurora Veil", "epic", "daily",
        _bg("#0a1a33") +
        '<g fill="#ffffff"><circle cx="20" cy="18" r="3"/><circle cx="64" cy="10" r="3"/><circle cx="142" cy="14" r="3"/><circle cx="110" cy="8" r="3"/></g>'
        '<path d="M0 64C40 14 100 84 160 24V50C100 110 40 40 0 90z" fill="#3fe0a5"/>'
        '<path d="M0 82C40 32 100 102 160 42V62C100 122 40 52 0 104z" fill="#7f5af0" opacity=".85"/>'
        '<path d="M0 120V100L30 84L58 104L88 80L120 106L160 86V120z" fill="#060d18"/>'),
    "moon_gate": ("Moon Gate", "epic", "daily",
        _bg("#8a2b2b") +
        '<circle cx="80" cy="60" r="40" fill="#f3e6c4"/><circle cx="98" cy="42" r="11" fill="#ffffff"/>'
        '<path d="M51.4 88C66 66 94 66 108.6 88A40 40 0 0 1 51.4 88z" fill="#2f7d4a"/>'
        '<circle cx="80" cy="60" r="44" fill="none" stroke="#f2c230" stroke-width="9"/>'),
    "ember_phoenix": ("Ember Phoenix", "epic", "daily",
        _bg("#3a1230") +
        '<path d="M72 64C52 52 30 44 6 24C10 46 16 64 8 80C26 78 44 80 72 74z" fill="#e2483d"/><path d="M72 64C54 56 40 52 24 40C28 56 30 64 26 72C40 72 56 74 72 72z" fill="#f08a24"/>'
        + _FLIP +
        '<path d="M72 64C52 52 30 44 6 24C10 46 16 64 8 80C26 78 44 80 72 74z" fill="#e2483d"/><path d="M72 64C54 56 40 52 24 40C28 56 30 64 26 72C40 72 56 74 72 72z" fill="#f08a24"/></g>'
        '<path d="M80 100L66 118L80 110L94 118z" fill="#e2483d"/>'
        '<path d="M80 18C90 28 90 40 86 48C98 64 98 84 80 106C62 84 62 64 74 48C70 40 70 28 80 18z" fill="#ffd23f"/>'),

    # ---- legendary (5) ----
    "sunlit_citadel": ("Sunlit Citadel", "legendary", "daily",
        _bg("#3d1a5e") +
        '<g fill="#5a2a88">' + _rot('<path d="M80 70L58-60H102z"/>', range(0, 360, 36), 80, 70) + '</g>'
        '<g fill="#f2c230"><rect x="62" y="56" width="36" height="52"/><rect x="34" y="70" width="26" height="38"/><rect x="100" y="70" width="26" height="38"/><rect y="106" width="160" height="14"/></g>'
        '<g fill="#e8941a"><path d="M58 56L80 22L102 56z"/><path d="M32 70L47 46L62 70z"/><path d="M98 70L113 46L128 70z"/></g>'
        '<rect x="78" y="8" width="5" height="16" fill="#f2c230"/><path d="M83 8H100L92 14L100 20H83z" fill="#ffffff"/>'
        '<path d="M72 108V90a8 8 0 0 1 16 0V108z" fill="#3d1a5e"/><rect x="77" y="64" width="6" height="12" fill="#3d1a5e"/><rect x="44" y="82" width="6" height="12" fill="#3d1a5e"/><rect x="110" y="82" width="6" height="12" fill="#3d1a5e"/>'),
    "golden_kraken": ("Golden Kraken", "legendary", "daily",
        _bg("#0f4a52") +
        '<g fill="#fff1d6"><circle cx="24" cy="30" r="5"/><circle cx="136" cy="20" r="4"/><circle cx="142" cy="62" r="6"/><circle cx="18" cy="72" r="4"/><circle cx="124" cy="94" r="4"/></g>' +
        _ARMS + _FLIP + _ARMS + '</g>'
        '<ellipse cx="80" cy="44" rx="32" ry="30" fill="#f2c230"/><circle cx="68" cy="46" r="6" fill="#0b2a2e"/><circle cx="92" cy="46" r="6" fill="#0b2a2e"/>'
        '<path d="M60 28C70 20 90 20 100 28" fill="none" stroke="#e8941a" stroke-width="5" stroke-linecap="round"/>'),
    "total_eclipse": ("Total Eclipse", "legendary", "daily",
        _bg("#14213d") +
        '<g transform="translate(80 60)" fill="#f2c230">' +
        _rot('<path d="M-7-42L0-66L7-42z"/>', range(0, 360, 45), 0, 0) +
        _rot('<path d="M-5-42L0-56L5-42z"/>', range(22, 360, 45), 0, 0) +
        '</g><circle cx="80" cy="60" r="44" fill="none" stroke="#ffd23f" stroke-width="5"/>'
        '<circle cx="80" cy="60" r="38" fill="#0b0b10"/>'),
    "golden_hoard": ("Golden Hoard", "legendary", "daily",
        _bg("#0f3d3a") +
        '<g fill="#ffd23f" stroke="#b8860b" stroke-width="4"><circle cx="38" cy="40" r="13"/><circle cx="122" cy="40" r="13"/></g>'
        '<rect x="30" y="68" width="100" height="42" rx="4" fill="#8a4b2a"/><path d="M30 68V58C30 40 130 40 130 58V68z" fill="#a0592f"/>'
        '<rect x="70" y="44" width="20" height="66" fill="#f2c230"/><rect x="30" y="66" width="100" height="6" fill="#f2c230"/>'
        '<rect x="68" y="68" width="24" height="20" rx="3" fill="#ffd23f"/><circle cx="80" cy="76" r="4" fill="#3b2412"/>'
        '<path d="M80 6L98 24L80 46L62 24z" fill="#e2483d"/><path d="M80 6L98 24L80 24z" fill="#ff8a7a"/>'),
    "celestial_orrery": ("Celestial Orrery", "legendary", "daily",
        _bg("#1b1240") +
        '<g fill="none" stroke="#f2c230" stroke-width="4"><circle cx="80" cy="60" r="20"/><circle cx="80" cy="60" r="36"/><circle cx="80" cy="60" r="52"/></g>'
        '<circle cx="80" cy="60" r="12" fill="#ffd23f"/><circle cx="80" cy="40" r="6" fill="#ffffff"/>'
        '<circle cx="105" cy="35" r="9" fill="#5fd0ff"/><circle cx="28" cy="60" r="10" fill="#ff7ab8"/><circle cx="117" cy="97" r="9" fill="#7bd389"/>'
        '<g fill="#ffffff"><circle cx="14" cy="14" r="3"/><circle cx="146" cy="16" r="3"/><circle cx="144" cy="108" r="3"/><circle cx="16" cy="106" r="3"/></g>'),
}
