
scalaprojects=bin/bindump bin/lua

.PHONY: $(scalaprojects) test jstest monitor-test

#$(scalaprojects): bin/%:
#	cd scala; sbt $*/package $*/start-script
#	echo -e "#!/bin/sh\n$(realpath scala/$*/target/start) \$$@" > $@
#	chmod +x $@

bin/cu:
	cd scala; sbt cuJVM/package cuJVM/start-script
	echo -e "#!/bin/sh\n$(realpath scala/cu/jvm/target/start) \$$@" > $@
	chmod +x $@

bin/machine: nim/*.nim
	nim --checks:on -o:$@ c nim/main.nim

bin/nimtest: nim/*.nim
	nim --checks:on -o:$@ c nim/test.nim

bin/nimtest.js: nim/*.nim
	nim js -d:nodejs --checks:on -o:$@ nim/test.nim

test: bin/nimtest
	bin/nimtest

jstest: bin/nimtest.js
	node bin/nimtest.js

monitor-test:
	while inotifywait -q -e close_write nim/; do nim --checks:on -o:bin/nimtest c -r nim/test.nim; done

