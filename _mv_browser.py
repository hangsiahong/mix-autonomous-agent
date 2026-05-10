#!/usr/bin/env python3
import json
path = "brain/tools.json"
tools = json.load(open(path))
for t in tools:
    if t["name"] == "browser":
        t["toolset"] = "search"
        print("moved browser to search toolset")
        break
json.dump(tools, open(path, "w"), indent=2)
print("done")
