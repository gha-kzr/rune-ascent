# Credits

Third-party assets used in the game: where they come from and their license. Add a row
whenever an external file is added (downloaded, bought or copied), in the same commit.

| Asset | Files | Source | Author | License |
|---|---|---|---|---|
| Spell and status icons | `ui/icons/*.svg` (recolored white, background removed) | [game-icons.net](https://game-icons.net) — [github.com/game-icons/icons](https://github.com/game-icons/icons) | Lorc, Delapouite, Carl Olsen, Sbed, Zeromancer | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| Fredoka font | `ui/fonts/Fredoka.ttf` | [Google Fonts](https://fonts.google.com/specimen/Fredoka) — [github.com/google/fonts/tree/main/ofl/fredoka](https://github.com/google/fonts/tree/main/ofl/fredoka) | The Fredoka Project Authors | [SIL Open Font License 1.1](ui/fonts/OFL.txt) |

## Icon files by author

| Author | Icons (game-icons.net name → file) |
|---|---|
| Lorc | arrow-flights → `arrow`, broken-bone → `crippling_blow`, fireball → `fireball`, earth-crack → `ground_slam`, foot-trip → `hamstring`, spear-hook → `piercing_thrust`, poison-bottle → `poison_arrow`, sword-slice → `slash`, hammer-drop → `smash`, arrow-cluster → `volley`, sword-spin → `whirlwind`, bleeding-wound → `status_crippled`, shield-reflect → `status_guarded`, skull-crossed-bones → `skull`, crossed-swords → `spell_default`, lightning-tear → `status_default`, sunbeams → `smite`, teleport → `blink`, sonic-boom → `repulse`, ice-spear → `frost_lance`, backstab → `backslash`, grapple → `grapple_shot`, on-target → `hunters_mark`, snowflake-2 → `status_chilled`, terror → `status_dread`, heavy-arrow → `bone_arrow`, arrowed → `pinning_shot`, crossed-bones → `bone_rain`, claw-slashes → `rend`, gluttonous-smile → `devour`, frozen-orb → `chill_touch`, screaming → `wail`, bone-gnawer → `feast`, shield-echoes → `shield_wall`, mushroom-gills → `spore_hex`, mushroom-cloud → `spore_bolt`, wolf-head → `bite`, grab → `icy_grasp`, meteor-impact → `meteor`, cold-heart → `grave_chill` |
| Carl Olsen | flame → `firebolt` |
| Delapouite | healing → `mend`, charging-bull → `charge`, shield-bash → `shield_bash`, wood-club → `club`, mushrooms → `spore_mend`, dynamite → `dynamite` |
| Sbed | shield → `guard`, regeneration → `regeneration`, poison-cloud → `status_poison`, targeted → `status_marked`, pounce → `pounce`, poison-cloud → `miasma` (the same drawing as `status_poison`, for the spell) |
| Zeromancer | heart-plus → `status_regeneration` |
| Sound effects: click, last seconds of a turn, hit, footstep, defeat jingle | `assets/audio/sfx/*.ogg` | [Interface Sounds](https://kenney.nl/assets/interface-sounds), [Impact Sounds](https://kenney.nl/assets/impact-sounds), [Music Jingles](https://kenney.nl/assets/music-jingles) (source notes and file hashes: `assets/audio/SOURCE.md`) | Kenney (kenney.nl) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Music: hub track | `assets/audio/music/hub.mp3` | [The Field Of Dreams](https://opengameart.org/content/the-field-of-dreams) | pauliuw | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Music: boss track | `assets/audio/music/boss.mp3` | [Battle Theme A](https://opengameart.org/content/battle-theme-a) | cynicmusic | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Music: ordinary battle track | `assets/audio/music/battle.mp3` | [Battle Theme B for RPG](https://opengameart.org/content/battle-theme-b-for-rpg) | cynicmusic | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Sound effects: spell casts (fire, poison), death | `assets/audio/sfx/cast_fire.ogg`, `cast_poison.ogg`, `death.ogg` | [80 CC0 RPG SFX](https://opengameart.org/content/80-cc0-rpg-sfx) (notes and hashes: `assets/audio/SOURCE.md`) | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Sound effect: physical cast (swish) | `assets/audio/sfx/cast_physical.wav` | [Swishes Sound Pack](https://opengameart.org/content/swishes-sound-pack) | artisticdude | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Sound effect: fireball | `assets/audio/sfx/cast_fireball.wav` | [Fireball](https://opengameart.org/content/fireball-1) | Julien Matthey | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Sound effect: generic cast | `assets/audio/sfx/cast.ogg` | [Magic Spell SFX](https://opengameart.org/content/magic-spell-sfx) | JaggedStone | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Victory fanfare | `assets/audio/sfx/victory.wav` | [Victory Fanfare Short](https://opengameart.org/content/victory-fanfare-short) | cynicmusic | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Sound effect: heal | `assets/audio/sfx/heal.wav` | [Cure Magic](https://opengameart.org/content/cure-magic) | Someoneman | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| Rune Ascent title picture and emblem (icon) | `ui/branding/title_image.jpg`, `ui/branding/icon.png` | Provided by the project owner | The project owner | The project's own artwork |
| Relay server: WebSocket library (a dependency, not shipped in the game) | `server/package.json` | [ws](https://github.com/websockets/ws) | Einar Otto Stangvik and contributors | [MIT](https://github.com/websockets/ws/blob/master/LICENSE) |
