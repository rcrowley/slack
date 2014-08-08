prefix=/usr/local

all:

install:
	install -d ${prefix}/bin
	install slack.sh ${prefix}/bin/slack
