import Foundation

extension Config {
    /// The default config, parsed. The tests guarantee it's valid; if it somehow
    /// weren't, Tile would run with nothing configured rather than crash.
    public static var defaults: Config {
        (try? parse(Data(defaultJSON.utf8)))
            ?? Config()
    }

    /// Written to ~/.config/tile/config.json on first launch. Hand-formatted, because
    /// it's the file the user edits. Thirds use grids so they divide exactly.
    public static let defaultJSON = #"""
    {
      "gaps": { "outer": 0, "inner": 0 },
      "ignoredApps": [],

      "profiles": [
        { "id": "laptop", "displays": {
            "laptop": { "builtin": true } } },
        { "id": "desk", "displays": {
            "laptop":         { "builtin": true },
            "vertical-left":  { "name": "DELL S2722QC", "serial": 810894658 },
            "vertical-right": { "name": "DELL S2722QC", "serial": 825446978 } } }
      ],

      "layouts": [
        { "id": "left-half",    "name": "Left Half",    "rect": [0, 0, 0.5, 1] },
        { "id": "right-half",   "name": "Right Half",   "rect": [0.5, 0, 0.5, 1] },
        { "id": "top-half",     "name": "Top Half",     "rect": [0, 0, 1, 0.5] },
        { "id": "bottom-half",  "name": "Bottom Half",  "rect": [0, 0.5, 1, 0.5] },

        { "id": "top-left",     "name": "Top Left",     "rect": [0, 0, 0.5, 0.5] },
        { "id": "top-right",    "name": "Top Right",    "rect": [0.5, 0, 0.5, 0.5] },
        { "id": "bottom-left",  "name": "Bottom Left",  "rect": [0, 0.5, 0.5, 0.5] },
        { "id": "bottom-right", "name": "Bottom Right", "rect": [0.5, 0.5, 0.5, 0.5] },

        { "id": "left-third",        "name": "Left Third",        "grid": [3, 1], "cells": [0, 0, 1, 1] },
        { "id": "center-third",      "name": "Center Third",      "grid": [3, 1], "cells": [1, 0, 1, 1] },
        { "id": "right-third",       "name": "Right Third",       "grid": [3, 1], "cells": [2, 0, 1, 1] },
        { "id": "left-two-thirds",   "name": "Left Two Thirds",   "grid": [3, 1], "cells": [0, 0, 2, 1] },
        { "id": "right-two-thirds",  "name": "Right Two Thirds",  "grid": [3, 1], "cells": [1, 0, 2, 1] },

        { "id": "top-third",         "name": "Top Third",         "grid": [1, 3], "cells": [0, 0, 1, 1] },
        { "id": "middle-third",      "name": "Middle Third",      "grid": [1, 3], "cells": [0, 1, 1, 1] },
        { "id": "bottom-third",      "name": "Bottom Third",      "grid": [1, 3], "cells": [0, 2, 1, 1] },
        { "id": "top-two-thirds",    "name": "Top Two Thirds",    "grid": [1, 3], "cells": [0, 0, 1, 2] },
        { "id": "bottom-two-thirds", "name": "Bottom Two Thirds", "grid": [1, 3], "cells": [0, 1, 1, 2] },

        { "id": "full",         "name": "Full",         "rect": [0, 0, 1, 1] },
        { "id": "almost-full",  "name": "Almost Full",  "rect": [0.05, 0.05, 0.9, 0.9] },
        { "id": "center",       "name": "Center",       "center": true }
      ],

      "bindings": [
        { "keys": "ctrl+opt+left",  "cycle": ["left-half", "left-third", "left-two-thirds"] },
        { "keys": "ctrl+opt+left",  "when": { "orientation": "portrait" },
          "cycle": ["top-half", "top-third", "top-two-thirds"] },
        { "keys": "ctrl+opt+right", "cycle": ["right-half", "right-third", "right-two-thirds"] },
        { "keys": "ctrl+opt+right", "when": { "orientation": "portrait" },
          "cycle": ["bottom-half", "bottom-third", "bottom-two-thirds"] },
        { "keys": "ctrl+opt+up",    "layout": "top-half" },
        { "keys": "ctrl+opt+down",  "layout": "bottom-half" },

        { "keys": "ctrl+opt+u", "layout": "top-left" },
        { "keys": "ctrl+opt+i", "layout": "top-right" },
        { "keys": "ctrl+opt+j", "layout": "bottom-left" },
        { "keys": "ctrl+opt+k", "layout": "bottom-right" },

        { "keys": "ctrl+opt+d", "layout": "left-third" },
        { "keys": "ctrl+opt+f", "layout": "center-third" },
        { "keys": "ctrl+opt+g", "layout": "right-third" },
        { "keys": "ctrl+opt+e", "layout": "left-two-thirds" },
        { "keys": "ctrl+opt+t", "layout": "right-two-thirds" },
        { "keys": "ctrl+opt+d", "when": { "orientation": "portrait" }, "layout": "top-third" },
        { "keys": "ctrl+opt+f", "when": { "orientation": "portrait" }, "layout": "middle-third" },
        { "keys": "ctrl+opt+g", "when": { "orientation": "portrait" }, "layout": "bottom-third" },
        { "keys": "ctrl+opt+e", "when": { "orientation": "portrait" }, "layout": "top-two-thirds" },
        { "keys": "ctrl+opt+t", "when": { "orientation": "portrait" }, "layout": "bottom-two-thirds" },

        { "keys": "ctrl+opt+return",       "layout": "full" },
        { "keys": "ctrl+opt+shift+return", "layout": "almost-full" },
        { "keys": "ctrl+opt+c",            "layout": "center" },
        { "keys": "ctrl+opt+delete",       "action": "restore" },
        { "keys": "ctrl+opt+cmd+right",    "action": "next-display" },
        { "keys": "ctrl+opt+cmd+left",     "action": "previous-display" }
      ],

      "arrangements": []
    }
    """#
}
