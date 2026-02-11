#!/bin/bash
# test.sh

JSON_CFG="example.json"
CMD=""
options=""

# USE $JSON_CFG TO PASS "image.json"
CMD=$(../resolver.sh "$JSON_CFG" "build.cmd")
#options=$(./resolver.sh "$JSON_CFG" "build.options[]")

echo "Resolved CMD: $CMD"
#echo "Resulting Options: $options"
