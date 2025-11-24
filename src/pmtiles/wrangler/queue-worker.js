// Queue worker that consumes messages from the extracts queue, grabbing data and storing in R2.
export default {
  async queue(batch, env, ctx) {
    for (const message of batch.messages) {
      try{
        // Parse JSON body into variables
        const { url, file } = message.body;
        console.log(`Processing message file: ${file} from URL: ${url}`);

        // Try R2 first
        let object = await env.BUCKET.get(file);

        if (object) {
            // The file is already in R2 - presumably we got two messages for the same file.
            console.log(`File already in R2: ${file}`);
            await message.ack();
            continue;  // Skip to next message
        }

        const originResp = await fetch(url);
        if (!originResp.ok) {
            console.error(`Disappeared from origin - give up: ${originResp.status} ${originResp.statusText}`);
            await message.ack();
            continue;  // Skip to next message
        }

        const contentType = originResp.headers.get("content-type") || "application/octet-stream";
        const contentLength = originResp.headers.get("content-length");
        if (!contentLength) {
            console.error(`No content length from origin - give up: ${originResp.status} ${originResp.statusText}`);
            await message.ack();
            continue;  // Skip to next message
        }

        await env.BUCKET.put(file, originResp.body, { httpMetadata: { contentType } });
        console.log(`R2 upload completed for file: ${file}`);

        await message.ack();
      } catch (err) {
        // Maybe a network error - allow a retry.
        console.error("Failed to parse or handle message:", err);
      }
    }
  }
};
