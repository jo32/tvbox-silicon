import assert from "node:assert/strict";
import { test } from "node:test";
import { details } from "../src/details.ts";
import { TMDB } from "../src/tmdb.ts";

for (const type of ["tv", "movie"] as const) {
  test(`${type} details expose IMDb title IDs using the existing TMDB request`, async () => {
    for (const imdbID of ["tt1", "tt0111161", "tt12345678901234567890"]) {
      let requests = 0;
      const tmdb = new TMDB("test", async (input) => {
        requests++;
        const url = new URL(input);
        assert.equal(url.pathname, `/3/${type}/7`);
        if (type === "tv") assert.ok(url.searchParams.get("append_to_response")!.split(",").includes("external_ids"));
        return Response.json({ id: 7, name: "Series", title: "Film",
          ...(type === "tv" ? { external_ids: { imdb_id: imdbID } } : { imdb_id: imdbID }),
        });
      }, null);
      const value = await details(tmdb, type, 7, "en-US", null);
      assert.equal(value!.imdbID, imdbID);
      assert.equal(value!.mediaType, type);
      assert.equal(requests, 1);
    }
  });

  test(`${type} details return null for missing or malformed IMDb title IDs`, async () => {
    for (const imdbID of [undefined, null, 1234567, {}, [], "", "tt", "nm1234567", "TT1234567", "tt１２３",
      "tt123abc", "tt123/", " tt123", "tt123 ", "tt123\n", "tt123\r\n", "https://www.imdb.com/title/tt123", "tt123?x=1"]) {
      const tmdb = new TMDB("test", async () => Response.json({ id: 7,
        ...(type === "tv" ? { external_ids: { imdb_id: imdbID } } : { imdb_id: imdbID }),
      }), null);
      const value = await details(tmdb, type, 7, "en-US", null);
      assert.equal(value!.imdbID, null, `IMDb ID ${JSON.stringify(imdbID)}`);
    }
    const tmdb = new TMDB("test", async () => Response.json({ id: 7 }), null);
    assert.equal((await details(tmdb, type, 7, "en-US", null))!.imdbID, null);
  });
}
