export default {
  async fetch(request, env, ctx) {
    // Get the file out - that is the last part of the URL path
    console.log(`Request URL: ${request.url}`);
    const url = new URL(request.url);
    let file = url.pathname.slice(1);
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
      file = `${currentDatestamp}/${file}`;
    }

    console.log(`Looking for file: ${file}`);

    // Try R2 first
    let object = await env.BUCKET.get(file);

    if (! object) {
      // Not in R2 - fetch from origin
      const originUrl = `${originBaseUrl}/${file}`;
      console.log(`Not found in R2 - get from: ${originUrl}`);
      const originResp = await fetch(originUrl);

      if (!originResp.ok) {
        console.error(`Did not find in origin - give up: ${originResp.status} ${originResp.statusText}`);
        return new Response("Not found", { status: originResp.status });
      }

      const contentType = originResp.headers.get("content-type") || "application/octet-stream";
      const contentLength = originResp.headers.get("content-length");
      if (!contentLength) {
        throw new Error("Origin did not provide Content-Length");
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
      console.log(`Return data from R2`);
      return new Response(object.body, {
        headers: { "Content-Type": object.httpMetadata?.contentType || "application/octet-stream" }
      });
    }
  }
}