#!/usr/bin/env python
import json
import struct
try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen
try:
    from builtins import chr as unichr
except ImportError:
    pass



def unichar(i):
    try:
        return unichr(i)
    except ValueError:
        return struct.pack('i', i).decode('utf-32')


if __name__ == '__main__':
    response = urlopen("https://raw.githubusercontent.com/iamcal/emoji-data/master/emoji.json")
    emoji_map = {}
    for emoji in json.loads(response.read()):
        emoji_map[emoji["short_name"]] = u"".join(unichar(int(uc, 16)) for uc in emoji["unified"].split("-"))

    with open("emoji.json", "w") as f:
        json.dump(emoji_map, f, sort_keys=True, indent=4)
