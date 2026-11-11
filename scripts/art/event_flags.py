"""Limited event flags for the Flag Shop (original Conquest art).

THANKSGIVING (Bruno, 2026-11-11): six flags, on sale every year from a week
before US Thanksgiving to the Tuesday after (FlagShop.EVENTS). Themes: feast,
harvest, autumn, a warm home. Same format as flags.py OWN: key -> (name,
rarity, set, inner SVG body on a 160x120 viewBox). No imports, no side effects.
"""

THANKSGIVING = {
    # Legendary: the horn of plenty spilling fruit, gold on burgundy.
    "horn_of_plenty": ("Horn of Plenty", "legendary", "thanksgiving",
        '<rect width="160" height="120" fill="#5a1626"/>'
        '<path d="M0 0h160v10H0zM0 110h160v10H0z" fill="#d9a43a"/>'
        '<path d="M96 34C70 34 42 42 28 58C18 70 18 86 30 88C24 80 28 70 38 68C56 76 76 88 96 94z" fill="#c98a3a" stroke="#f2c14e" stroke-width="5" stroke-linejoin="round"/>'
        '<g stroke="#8a5a24" stroke-width="4" fill="none"><path d="M60 42c6 12 8 30 4 42"/><path d="M78 37c6 14 8 34 4 52"/></g>'
        '<ellipse cx="96" cy="64" rx="10" ry="30" fill="#7a4a1c" stroke="#f2c14e" stroke-width="5"/>'
        '<circle cx="116" cy="54" r="15" fill="#e8742a"/><path d="M116 39v-6" stroke="#4a6b2a" stroke-width="4"/>'
        '<circle cx="134" cy="80" r="12" fill="#c8302a"/><circle cx="110" cy="84" r="11" fill="#f2c14e"/>'
        '<g fill="#7b3f8c"><circle cx="134" cy="44" r="6"/><circle cx="142" cy="52" r="6"/><circle cx="130" cy="56" r="6"/><circle cx="140" cy="62" r="6"/></g>'
        '<path d="M150 30c-8 0-14 6-14 12 8 0 14-6 14-12z" fill="#5c9a3a"/>'),
    # Epic: a proud turkey, its fan tail in autumn bands.
    "harvest_turkey": ("Harvest Turkey", "epic", "thanksgiving",
        '<rect width="160" height="120" fill="#f1e2bf"/>'
        '<g transform="translate(80 78)">'
        '<path d="M0 0L-62-10A62 62 0 0 1 62-10z" fill="#c8302a"/>'
        '<path d="M0 0L-50-12A50 50 0 0 1 50-12z" fill="#e8742a"/>'
        '<path d="M0 0L-38-14A38 38 0 0 1 38-14z" fill="#f2c14e"/>'
        '</g>'
        '<ellipse cx="80" cy="82" rx="22" ry="24" fill="#6b3b1e"/>'
        '<circle cx="80" cy="54" r="12" fill="#6b3b1e"/>'
        '<circle cx="76" cy="51" r="3" fill="#f1e2bf"/><circle cx="76" cy="51" r="1.5" fill="#1a1a1a"/>'
        '<path d="M68 55l-10 3 10 3z" fill="#f2c14e"/>'
        '<path d="M70 60c-4 4-4 10 0 12 3-3 3-8 0-12z" fill="#c8302a"/>'
        '<path d="M70 104l-4 10M90 104l4 10" stroke="#e8742a" stroke-width="5" stroke-linecap="round"/>'
        '<rect y="114" width="160" height="6" fill="#a8742c"/>'),
    # Epic: a log cabin with a lit window and smoke, under an orange dusk.
    "hearth_cabin": ("Hearth Cabin", "epic", "thanksgiving",
        '<rect width="160" height="120" fill="#2a2140"/>'
        '<rect y="70" width="160" height="50" fill="#e07a2a"/>'
        '<circle cx="128" cy="34" r="12" fill="#f3e2a8"/><circle cx="133" cy="30" r="11" fill="#2a2140"/>'
        '<rect y="96" width="160" height="24" fill="#5a3418"/>'
        '<path d="M44 62L80 34l36 28z" fill="#8a2a22"/>'
        '<rect x="50" y="62" width="60" height="38" fill="#7a4a24"/>'
        '<g stroke="#5a3418" stroke-width="3"><path d="M50 72h60M50 82h60M50 92h60"/></g>'
        '<rect x="58" y="70" width="18" height="16" fill="#ffd86a" stroke="#3a2412" stroke-width="3"/>'
        '<rect x="86" y="74" width="14" height="26" fill="#3a2412"/>'
        '<rect x="96" y="40" width="8" height="16" fill="#5a3418"/>'
        '<g fill="none" stroke="#d8d0c0" stroke-width="4" stroke-linecap="round"><path d="M100 34c-6-6 6-10 0-16"/></g>'),
    # Rare: three pumpkins on a field row.
    "pumpkin_patch": ("Pumpkin Patch", "rare", "thanksgiving",
        '<rect width="160" height="120" fill="#4a6b3a"/>'
        '<rect y="88" width="160" height="32" fill="#6b4424"/>'
        '<g fill="#e8742a" stroke="#b8501a" stroke-width="3">'
        '<ellipse cx="46" cy="80" rx="22" ry="17"/><ellipse cx="114" cy="82" rx="20" ry="15"/><ellipse cx="80" cy="72" rx="28" ry="22"/></g>'
        '<g fill="none" stroke="#b8501a" stroke-width="3"><path d="M80 50v44M66 54c-6 12-6 26 0 38M94 54c6 12 6 26 0 38"/></g>'
        '<g fill="#4a3018"><rect x="77" y="42" width="6" height="10" rx="2"/><rect x="43" y="58" width="5" height="7" rx="2"/><rect x="111" y="62" width="5" height="7" rx="2"/></g>'
        '<path d="M84 46c8-6 16-2 18 4-8 2-14 0-18-4z" fill="#8fbf4a"/>'),
    # Rare: a tied sheaf of golden wheat.
    "golden_sheaf": ("Golden Sheaf", "rare", "thanksgiving",
        '<rect width="160" height="120" fill="#2f5a4a"/>'
        '<g stroke="#f2c14e" stroke-width="5" stroke-linecap="round" fill="none">'
        '<path d="M80 108V42"/><path d="M80 108L62 46"/><path d="M80 108L98 46"/><path d="M80 108L48 58"/><path d="M80 108L112 58"/></g>'
        '<g fill="#f2c14e"><g transform="translate(80 40) rotate(0)"><ellipse cx="-4" cy="-2" rx="4.5" ry="7" transform="rotate(-25 -4 -2)"/><ellipse cx="4" cy="-2" rx="4.5" ry="7" transform="rotate(25 4 -2)"/><ellipse cx="-4" cy="-12" rx="4.5" ry="7" transform="rotate(-25 -4 -12)"/><ellipse cx="4" cy="-12" rx="4.5" ry="7" transform="rotate(25 4 -12)"/><ellipse cx="-4" cy="-22" rx="4.5" ry="7" transform="rotate(-25 -4 -22)"/><ellipse cx="4" cy="-22" rx="4.5" ry="7" transform="rotate(25 4 -22)"/><ellipse cx="0" cy="-31" rx="4.5" ry="7" transform="rotate(0 0 -31)"/></g><g transform="translate(61 44) rotate(-18)"><ellipse cx="-4" cy="-2" rx="4.5" ry="7" transform="rotate(-25 -4 -2)"/><ellipse cx="4" cy="-2" rx="4.5" ry="7" transform="rotate(25 4 -2)"/><ellipse cx="-4" cy="-12" rx="4.5" ry="7" transform="rotate(-25 -4 -12)"/><ellipse cx="4" cy="-12" rx="4.5" ry="7" transform="rotate(25 4 -12)"/><ellipse cx="-4" cy="-22" rx="4.5" ry="7" transform="rotate(-25 -4 -22)"/><ellipse cx="4" cy="-22" rx="4.5" ry="7" transform="rotate(25 4 -22)"/><ellipse cx="0" cy="-31" rx="4.5" ry="7" transform="rotate(0 0 -31)"/></g><g transform="translate(99 44) rotate(18)"><ellipse cx="-4" cy="-2" rx="4.5" ry="7" transform="rotate(-25 -4 -2)"/><ellipse cx="4" cy="-2" rx="4.5" ry="7" transform="rotate(25 4 -2)"/><ellipse cx="-4" cy="-12" rx="4.5" ry="7" transform="rotate(-25 -4 -12)"/><ellipse cx="4" cy="-12" rx="4.5" ry="7" transform="rotate(25 4 -12)"/><ellipse cx="-4" cy="-22" rx="4.5" ry="7" transform="rotate(-25 -4 -22)"/><ellipse cx="4" cy="-22" rx="4.5" ry="7" transform="rotate(25 4 -22)"/><ellipse cx="0" cy="-31" rx="4.5" ry="7" transform="rotate(0 0 -31)"/></g><g transform="translate(46 54) rotate(-34)"><ellipse cx="-4" cy="-2" rx="4.5" ry="7" transform="rotate(-25 -4 -2)"/><ellipse cx="4" cy="-2" rx="4.5" ry="7" transform="rotate(25 4 -2)"/><ellipse cx="-4" cy="-12" rx="4.5" ry="7" transform="rotate(-25 -4 -12)"/><ellipse cx="4" cy="-12" rx="4.5" ry="7" transform="rotate(25 4 -12)"/><ellipse cx="-4" cy="-22" rx="4.5" ry="7" transform="rotate(-25 -4 -22)"/><ellipse cx="4" cy="-22" rx="4.5" ry="7" transform="rotate(25 4 -22)"/><ellipse cx="0" cy="-31" rx="4.5" ry="7" transform="rotate(0 0 -31)"/></g><g transform="translate(114 54) rotate(34)"><ellipse cx="-4" cy="-2" rx="4.5" ry="7" transform="rotate(-25 -4 -2)"/><ellipse cx="4" cy="-2" rx="4.5" ry="7" transform="rotate(25 4 -2)"/><ellipse cx="-4" cy="-12" rx="4.5" ry="7" transform="rotate(-25 -4 -12)"/><ellipse cx="4" cy="-12" rx="4.5" ry="7" transform="rotate(25 4 -12)"/><ellipse cx="-4" cy="-22" rx="4.5" ry="7" transform="rotate(-25 -4 -22)"/><ellipse cx="4" cy="-22" rx="4.5" ry="7" transform="rotate(25 4 -22)"/><ellipse cx="0" cy="-31" rx="4.5" ry="7" transform="rotate(0 0 -31)"/></g></g>'
        '<rect x="66" y="78" width="28" height="9" rx="3" fill="#8a2a22"/>'),
    # Rare: oak leaves and acorns falling on a russet field.
    "acorn_fall": ("Acorn Fall", "rare", "thanksgiving",
        '<rect width="160" height="120" fill="#a8461e"/>'
        '<rect y="0" width="160" height="12" fill="#f1e2bf"/><rect y="108" width="160" height="12" fill="#f1e2bf"/>'
        '<g transform="translate(46 58) rotate(-28) scale(1.45)"><path d="M0 -30C6 -28 6 -22 4 -20C10 -20 12 -14 8 -10C14 -10 16 -2 10 2C16 4 16 12 10 14C12 20 6 24 2 22L2 34L-2 34L-2 22C-6 24 -12 20 -10 14C-16 12 -16 4 -10 2C-16 -2 -14 -10 -8 -10C-12 -14 -10 -20 -4 -20C-6 -22 -6 -28 0 -30Z" fill="#f2c14e"/><path d="M0 -24V30" stroke="#a8461e" stroke-width="2"/></g>'
        '<g transform="translate(84 40) rotate(36) scale(.8)"><path d="M0 -30C6 -28 6 -22 4 -20C10 -20 12 -14 8 -10C14 -10 16 -2 10 2C16 4 16 12 10 14C12 20 6 24 2 22L2 34L-2 34L-2 22C-6 24 -12 20 -10 14C-16 12 -16 4 -10 2C-16 -2 -14 -10 -8 -10C-12 -14 -10 -20 -4 -20C-6 -22 -6 -28 0 -30Z" fill="#6e1f14"/></g>'
        '<g transform="translate(116 60) rotate(14)">'
        '<ellipse cx="0" cy="10" rx="14" ry="18" fill="#6b3b1e"/>'
        '<path d="M-17 -2a17 11 0 0 1 34 0z" fill="#3e2412"/><rect x="-2" y="-20" width="4" height="10" fill="#3e2412"/></g>'
        '<g transform="translate(138 92) rotate(-20) scale(.55)">'
        '<ellipse cx="0" cy="10" rx="14" ry="18" fill="#6b3b1e"/>'
        '<path d="M-17 -2a17 11 0 0 1 34 0z" fill="#3e2412"/><rect x="-2" y="-20" width="4" height="10" fill="#3e2412"/></g>'),
}
