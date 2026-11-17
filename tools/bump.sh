#!/bin/sh
# 배포 전 실행: 앱 버전을 올려서 열려 있는 화면이 새 버전으로 자동 새로고침되게 함
v=$(TZ=Asia/Seoul date +%Y%m%d%H%M%S)
sed -i "s/const APP_VER='[0-9]*'/const APP_VER='$v'/" app/index.html
echo "$v" > app/ver.txt
echo "$v"
