[ a = b ]
echo $? # 1
test a = a
echo $? # 0
#[ ]
#echo $? # 1
[ abc ]
echo $? # 0
[ ! abc ]
echo $? # 1
#[ ! ]
#echo $?
#[ abc -a bcd ]
#echo $?
#[ abc -o bcd ]
#echo $?
test abc == abd
echo $? # 1
[ abc != bcd ]
echo $? # 0
[ abc != abc ]
echo $? # 1
[ abc \> bcd ]
echo $? # 1
[ abc \< bcd ]
echo $? # 0
[[ abc ]] && echo true1
[[ abc < bcd ]] && echo true2
[[ abc > bcd ]] || echo true3
[[ abc != bcd ]] && echo true4
[[ abc = bcd ]] || echo true5
[[ abc == abc ]] && echo true6
[[ ! abc = bcd ]] && echo true7
[[ abc = bcd || abc == abc ]] && echo true8
[[ abc = bcd && abc == abc ]] || echo true9
# abc=bcd is treated as a simple string
[[ abc=bcd && abc == abc ]] || echo wrong
[[ -a "/" ]] && echo "true10"
[[ . -ef . ]] && echo "true11"
[[ 2 -ge 2 ]] && echo "true12"
[[ "abc def xyz" == *"def"* ]] && echo "true13"
[[ "abc def xyz" == *"defg"* ]] && echo "wrong"
[[ "abc def xyz" != *"def"* ]] && echo "wrong"
[[ "abc def xyz" != *"defg"* ]] && echo "true14"
shopt -s extglob
[[ "123" == *([[:digit:]]) ]] && echo "true15"
i=2
[[ i++ -gt 2 ]] && echo wrong
[[ i++ -gt 2 ]] && echo true16
unset i
[[ "setup.py" =~ ^(setup\.py|nosetests|py\.test|trial(\ .*)?)$ ]] && echo true17
[[ "setup.py" =~ ^(setup\.p|nosetests|py\.test|trial(\ .*)?)$ ]] && echo false
[ abc = bcd -o abc = abc ] && echo true18
[ abc = bcd -a abc = abc ] || echo true19
[[ =a <=b ]]
[[ =a >=b ]]
[[ a == a || c == b && a == b ]] && echo true
i=1
[[ a == b || $((i=0)) ]] && echo $i # i should be 0 now
[[ a == a || $((i=1)) ]] && echo $i # i should still be 0
[[ a == b && $((i=1)) ]] || echo $i # i should still be 0
i=1
[[ a == a && $((i=0)) ]] && echo $i # i should still be 0
[ -n "a" -o -n "" -a -n "" ] && echo true
# builtin test doesn't support shortcut
i=1
[ 1 -eq 2 -o $((i=0)) ] && echo $i # i should be 0 now
[ 1 -eq 1 -o $((i=1)) ] && echo $i # i should still be 1
[ 1 -eq 2 -a $((i=1)) ] || echo $i # i should still be 1
i=1
[ 1 -eq 1 -a $((i=0)) ] && echo $i # i should still be 0
