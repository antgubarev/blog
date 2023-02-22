build:
	hugo --minify

clean:
	rm -Rf public/ resources/_gen/

server:
	hugo server
