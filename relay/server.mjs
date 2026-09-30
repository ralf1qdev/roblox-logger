import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
const webhook = process.env.DISCORD_WEBHOOK_URL;
const key = process.env.SIGNAL_RELAY_KEY;
if (!webhook || !/^https:\/\/discord\.com\/api\/(v\d+\/)?webhooks\/\d+\/[A-Za-z0-9_-]+$/.test(webhook) || !key || key.length < 32) {
  throw new Error('Set a valid DISCORD_WEBHOOK_URL (no query) and SIGNAL_RELAY_KEY (32+ characters).');
}
const destination = new URL(webhook); destination.searchParams.set('wait', 'true');
let busy = false;
let nextAllowed = 0;
const reply = (res, code, data, headers={}) => {
  res.writeHead(code, {'Content-Type':'application/json', ...headers});
  res.end(JSON.stringify(data));
};
http.createServer(async (req, res) => {
  if (req.method !== 'POST' || req.url !== '/events') return reply(res, 404, {error:'Not found'});
  const provided = Buffer.from(req.headers.authorization || '');
  const expected = Buffer.from(`Bearer ${key}`);
  if (provided.length !== expected.length || !timingSafeEqual(provided, expected)) return reply(res, 401, {error:'Unauthorized'});
  if (busy || Date.now() < nextAllowed) {
    const seconds = Math.max(1, (nextAllowed-Date.now())/1000);
    return reply(res, 429, {retry_after:seconds}, {'Retry-After':String(seconds)});
  }
  busy = true;
  try {
    const chunks=[]; let bytes=0;
    for await (const chunk of req) {
      bytes += chunk.length;
      if(bytes > 32768) { reply(res, 413, {error:'Payload too large'}); return; }
      chunks.push(chunk);
    }
    let payload;
    try { payload = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { return reply(res, 400, {error:'Invalid JSON'}); }
    if(!Array.isArray(payload.embeds) || payload.embeds.length !== 1) return reply(res, 400, {error:'Expected one embed'});
    const upstream = await fetch(destination, {
      method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({username:'Signal', embeds:payload.embeds, allowed_mentions:{parse:[]}}),
      signal:AbortSignal.timeout(12000),
    });
    const remaining = upstream.headers.get('x-ratelimit-remaining');
    const reset = Number(upstream.headers.get('x-ratelimit-reset-after')) || 0;
    if (remaining === '0') nextAllowed = Date.now() + Math.max(1000, reset*1000);
    if(upstream.status === 429) {
      const body = await upstream.json().catch(()=>({}));
      const seconds = Math.max(1, Number(body.retry_after) || Number(upstream.headers.get('retry-after')) || 5);
      nextAllowed = Date.now()+seconds*1000;
      return reply(res, 429, {retry_after:seconds}, {'Retry-After':String(seconds)});
    }
    if(upstream.ok) return reply(res, 200, {ok:true});
    return reply(res, upstream.status, {error:'Webhook delivery failed'});
  } catch {
    reply(res, 502, {error:'Webhook request failed'});
  } finally { busy = false; }
}).listen(Number(process.env.PORT || 8080), '0.0.0.0', () => console.log('Signal relay listening'));
