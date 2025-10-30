# PMTiles repo

This subdirectory is a copy of part of the [protomaps PMTiles repository](https://github.com/protomaps/PMTiles).

- All contents (except this README) are licensed according to the [license file from that repo, copied here](LICENSE).

- The [serverless](serverless) directory is copied from that repo directly.

- The [wrangler](wrangler) directory contains built code. To build this code, run the following commands from this directory.

    ~~~bash
    # Install the pmtiles npm package
    npm i pmtiles
    # Build worker code
    npx esbuild serverless/cloudflare/src/index.ts --bundle --format=esm --outfile=wrangler/tiles.js
    ~~~

The current code is from the `main` branch, at commit `e232df55745642b39f0cc1edfc85df2633bce29c`.

