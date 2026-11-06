.PHONY: build test app run clean

## Compile tous les modules (debug)
build:
	swift build

## Lance les tests unitaires (les tests d'intégration sont ignorés sans serveur)
test:
	swift test

## Construit build/MaxFtp.app (release, signé ad hoc)
app:
	Scripts/build-app.sh release

## Construit puis ouvre l'application
run: app
	open build/MaxFtp.app

clean:
	swift package clean
	rm -rf build
