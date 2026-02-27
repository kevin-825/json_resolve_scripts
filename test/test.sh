#!/bin/bash
# test.sh

JSON_CFG="image.json"
CMD=""
options=""

# USE $JSON_CFG TO PASS "image.json"

#options=$(../resolver.sh "$JSON_CFG" "build.options[]")
#echo -e "Resolved options: \n$options" | sed -r 's/[[:space:]]{4,}/    \n  /g'

CMD=$(../resolver.sh "$JSON_CFG" "build.cmd")
echo -e "Resolved CMD: \n$CMD" | sed -r 's/[[:space:]]{4,}/    \n  /g'

#echo "Resulting Options: $options"
