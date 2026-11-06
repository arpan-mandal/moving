#!/usr/bin/env python3
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias
volume = Path(sys.argv[1])
with DSStore.open(str(volume/'.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar':False, 'ShowToolbar':False, 'ShowPathbar':False,
        'ShowSidebar':False, 'ContainerShowSidebar':False,
        'WindowBounds':'{{200, 150}, {660, 410}}', 'PreviewPaneVisibility':False,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion':1, 'backgroundType':2,
        'backgroundColorRed':0.08, 'backgroundColorGreen':0.10, 'backgroundColorBlue':0.08,
        'backgroundImageAlias':Alias.for_file(str(volume/'.background/install.png')).to_bytes(),
        'iconSize':96.0, 'textSize':13.0, 'labelOnBottom':True, 'showItemInfo':False,
        'showIconPreview':True, 'arrangeBy':'none', 'gridOffsetX':0.0, 'gridOffsetY':0.0, 'gridSpacing':100.0,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['Moving.app']['Iloc'] = (174, 205)
    store['Applications']['Iloc'] = (486, 205)
