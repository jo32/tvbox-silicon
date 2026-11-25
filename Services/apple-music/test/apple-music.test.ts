import assert from "node:assert/strict";
import { test } from "node:test";
import { AppleMusic } from "../src/apple.ts";
import { album, artist, baseTitle, identify, pickSong, plain, song, splitArtists } from "../src/catalog.ts";
import { answer, readInput } from "../src/index.ts";
import { developerToken, LIFETIME } from "../src/token.ts";

const entry = (id: string, name: string, artistName: string, seconds: number, extra: Record<string, unknown> = {}) =>
  ({ id, type: "songs", attributes: { name, artistName, albumName: "叶惠美", durationInMillis: seconds * 1000, isrc: `TW${id}`, genreNames: ["华语流行", "音乐"],
    artwork: { url: "https://is1.mzstatic.com/x/{w}x{h}bb.jpg" }, releaseDate: "2003-07-31", url: `https://music.apple.com/cn/song/${id}`, ...extra } });

/// Answers Apple Music paths from a table, recording what was asked.
function fake(table: Record<string, unknown>) {
  const asked: URL[] = [];
  const apple = new AppleMusic(async () => "token", async (input, init) => {
    const url = new URL(input);
    asked.push(url);
    assert.equal((init?.headers as Record<string, string>).authorization, "Bearer token");
    const body = table[url.pathname];
    return body === undefined ? new Response(null, { status: 404 }) : Response.json(body);
  }, null);
  return { apple, asked };
}

test("the developer token is an ES256 JWT the key's public half verifies", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
  const token = await developerToken(pem, "KEY123", "TEAM456", 1_800_000_000);
  const [header, payload, signature] = token.split(".");
  const decode = (part: string) => Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(decode(header))), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(decode(payload))), { iss: "TEAM456", iat: 1_800_000_000, exp: 1_800_000_000 + LIFETIME });
  assert.equal(decode(signature).length, 64);
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, decode(signature), new TextEncoder().encode(`${header}.${payload}`)));
});

test("titles compare without versions or width, artists split on Apple's joins", () => {
  assert.equal(baseTitle("晴天 (Live)"), baseTitle("晴天"));
  assert.equal(baseTitle("Ｌｏｖｅ Ｓｔｏｒｙ"), baseTitle("love story"));
  assert.equal(baseTitle("稻香 - 现场版"), "稻香");
  assert.deepEqual(splitArtists("周杰伦 & 杨瑞代, 费玉清"), ["周杰伦", "杨瑞代", "费玉清"]);
  assert.deepEqual(splitArtists("Ed Sheeran feat. Taylor Swift"), ["Ed Sheeran", "Taylor Swift"]);
  assert.equal(plain("<p>One &amp; two<br>three</p>"), "One & two\nthree");
});

test("a song is identified by title, artist and length, never by title alone", () => {
  const songs = [entry("1", "晴天", "某翻唱", 269), entry("2", "晴天 (Live)", "周杰伦", 330), entry("3", "晴天", "周杰伦", 269.5)].map(song).filter((s) => s !== null);
  assert.equal(pickSong({ title: "晴天", artists: ["周杰伦"], duration: 268 }, songs)?.id, "3");
  // The live take is another length: not this recording.
  assert.equal(pickSong({ title: "晴天", artists: ["周杰伦"], duration: 330 }, songs)?.id, "2");
  assert.equal(pickSong({ title: "晴天", artists: ["林俊杰"], duration: 269 }, songs), null);
  assert.equal(pickSong({ title: "稻香", artists: ["周杰伦"], duration: 223 }, songs), null);
});

test("identify searches the storefront's songs and trims what it answers", async () => {
  const { apple, asked } = fake({ "/v1/catalog/cn/search": { results: { songs: { data: [entry("9", "晴天", "周杰伦", 269)] } } } });
  const found = await identify(apple, "cn", { title: "晴天", artists: ["周杰伦"], duration: 270 });
  assert.equal(asked[0].searchParams.get("term"), "晴天 周杰伦");
  assert.equal(asked[0].searchParams.get("types"), "songs");
  assert.deepEqual(found, { id: "9", title: "晴天", artist: "周杰伦", artists: ["周杰伦"], album: "叶惠美", duration: 269, isrc: "TW9",
    released: "2003-07-31", genres: ["华语流行"], artwork: "https://is1.mzstatic.com/x/{w}x{h}bb.jpg", url: "https://music.apple.com/cn/song/9" });
});

test("an artist is the search result with that exact name, with its notes, top songs and albums", async () => {
  const { apple, asked } = fake({
    "/v1/catalog/cn/search": { results: { artists: { data: [{ id: "5", attributes: { name: "周杰伦乐队" } }, { id: "6", attributes: { name: "周杰伦" } }] } } },
    "/v1/catalog/cn/artists/6": { data: [{ id: "6", attributes: { name: "周杰伦", genreNames: ["华语流行"], artwork: { url: "https://a/{w}x{h}.jpg" },
      editorialNotes: { standard: "<p>华语乐坛天王。</p>" }, url: "https://music.apple.com/cn/artist/6" },
      views: { "top-songs": { data: [entry("9", "晴天", "周杰伦", 269)] }, "full-albums": { data: [{ id: "7", attributes: { name: "叶惠美", artistName: "周杰伦", trackCount: 11 } }] } } }] },
  });
  const found = await artist(apple, "cn", "周杰伦");
  assert.equal(found?.id, "6");
  assert.equal(found?.notes, "华语乐坛天王。");
  assert.deepEqual(found?.topSongs.map((s) => s.title), ["晴天"]);
  assert.deepEqual(found?.albums.map((a) => [a.title, a.trackCount]), [["叶惠美", 11]]);
  assert.equal(asked[1].searchParams.get("views"), "top-songs,full-albums");
  assert.equal(await artist(fake({ "/v1/catalog/cn/search": { results: {} } }).apple, "cn", "周杰伦"), null);
});

test("an album needs its title and one of its artists, and brings its notes, label and tracks", async () => {
  const { apple } = fake({
    "/v1/catalog/cn/search": { results: { albums: { data: [{ id: "1", attributes: { name: "叶惠美", artistName: "别人" } }, { id: "7", attributes: { name: "叶惠美", artistName: "周杰伦" } }] } } },
    "/v1/catalog/cn/albums/7": { data: [{ id: "7", attributes: { name: "叶惠美", artistName: "周杰伦", recordLabel: "JVR Music", releaseDate: "2003-07-31", trackCount: 11,
      genreNames: ["华语流行", "音乐"], copyright: "℗ 2003 JVR", editorialNotes: { short: "经典。" } }, relationships: { tracks: { data: [entry("9", "晴天", "周杰伦", 269)] } } }] },
  });
  const found = await album(apple, "cn", "叶惠美", "周杰伦");
  assert.deepEqual([found?.id, found?.label, found?.notes, found?.genres, found?.tracks[0].isrc], ["7", "JVR Music", "经典。", ["华语流行"], "TW9"]);
});

test("only the three questions, with bounded inputs, are read", async () => {
  const read = (s: string) => readInput(new URL(`https://w${s}`));
  assert.deepEqual(read("/v1/identify?title=%E6%99%B4%E5%A4%A9&artist=%E5%91%A8%E6%9D%B0%E4%BC%A6&duration=269"),
    { kind: "identify", storefront: "cn", title: "晴天", artists: ["周杰伦"], duration: 269, name: "" });
  for (const bad of ["/v1/catalog/cn/search?term=x", "/v1/identify", "/v1/identify?title=x&storefront=zz", "/v1/identify?title=x&duration=-1",
    "/v1/identify?title=x&duration=abc", `/v1/artist?name=${"x".repeat(201)}`, "/v1/artist", "/v1/album?artist=x"]) assert.equal(read(bad), null, bad);
  const { apple } = fake({ "/v1/catalog/jp/search": { results: {} } });
  assert.deepEqual(await answer(apple, read("/v1/identify?title=x&storefront=jp")!), { song: null });
});
