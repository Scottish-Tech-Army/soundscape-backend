export default {
  async fetch(request, env, ctx) {
    // Get the file out - that is the last part of the URL path
    console.log(`Request URL: ${request.url}`);
    const url = new URL(request.url);
    let file = url.pathname.slice(1);
    let banCache = false;
    const originBaseUrl = env.ORIGIN_BASE_URL;
    const currentDatestamp = env.CURRENT_DATESTAMP;
    console.log(`originBaseUrl: ${originBaseUrl}`);
    console.log(`currentDatestamp: ${currentDatestamp}`);

    // Test if the client actually wants any data or is just priming R2
    const noData = url.searchParams.has("nodata");

    // Test if file starts with a date prefix "dddddddd-dddd-". If so, it is that directory.
    const prefixMatch = file.match(/^(\d{8}-\d{4})-/);
    if (prefixMatch) {
      console.log(`File has prefix: ${prefixMatch[1]}`);
      const prefix = prefixMatch[1];
      file = `${prefix}/${file}`;
    }
    else {
      // Not prefixed - use latest directory
      console.log(`No prefix - use latest directory`);
      // Special handling if file is exactly "manifest.geojson.gz"
      if (file === "manifest.geojson.gz") {
        console.log("Special case: manifest.geojson.gz so no caching allowed");
        // You can add custom logic here, for now just return 404 or handle as needed
        banCache = true;
      }
      file = `${currentDatestamp}/${file}`;
    }

    console.log(`Looking for file: ${file}`);

    // Try R2 first
    let object = await env.BUCKET.get(file);

    if (! object) {
      // Not in R2 - fetch from origin
      const originUrl = `${originBaseUrl}/${file}`;
      console.log(`Not found in R2 - get from: ${originUrl}`);

      // First: HEAD request to inspect headers
      const headResp = await fetch(originUrl, { method: "HEAD" });

      if (!headResp.ok) {
        console.error(`HEAD failed: ${headResp.status} ${headResp.statusText}`);
        return new Response("Not found", { status: headResp.status });
      }

      let contentType = headResp.headers.get("content-type") || "application/octet-stream";
      let contentLength = headResp.headers.get("content-length");
      if (!contentLength) {
        throw new Error("Origin HEAD did not provide Content-Length");
      }

      // Now check if this file is large enough that we should just put on a queue.
      // Threshold is 100MB
      const contentLengthMB = parseInt(contentLength, 10) / (1024 * 1024);
      if (contentLengthMB > 100) {
        console.log("Large file - pass to queue");
        await env.QUEUE.send({ url: originUrl, file: file });

        // We just return a 503 with a Retry-After. 5 minutes ought to be enough; it's really hard to predict.
        return new Response("File not yet available, please retry later", { status: 503, headers: { "Retry-After": "300" } });
      }

      // Now do the actual GET
      // We know this will work and what headers it will give, but recheck for paranoia.
      const originResp = await fetch(originUrl);
      if (!originResp.ok) {
        console.error(`Disappeared from origin - give up: ${originResp.status} ${originResp.statusText}`);
        return new Response("Not found", { status: originResp.status });
      }
      contentType = originResp.headers.get("content-type") || "application/octet-stream";
      contentLength = originResp.headers.get("content-length");

      if (!contentLength) {
        throw new Error("Origin GET did not provide Content-Length");
      }

      const putPromise = await env.BUCKET.put(file, originResp.body, {
        httpMetadata: { contentType }
      });

      // Keep writing even if client goes away.
      ctx.waitUntil(putPromise);

      // Wait for that write.
      await putPromise;
      console.log(`R2 upload completed`);

      // We now have got the data in R2, so go back to returning it.
      object = await env.BUCKET.get(file);
    }

    if (noData) {
      console.log(`No data requested - returning 204`);
      return new Response("", { status: 204 });
    }
    else {
      const headers = new Headers();
      headers.set("Content-Type", object.httpMetadata?.contentType || "application/octet-stream")

      let cacheControl;
      if (banCache) {
        // No caching
        cacheControl = "no-store, no-cache, must-revalidate";
      }
      else {
        // Cache for a week.
        cacheControl = "public, max-age=604800, immutable";
      }
      headers.set("Cache-Control", cacheControl);

      console.log(`Return data from R2 - cache header: ${cacheControl}`);
      return new Response(object.body, {
        headers: headers
      });
    }
  }
}