# Vietnamese administrative locations

`vietnam-locations.json` contains 34 provinces/cities and 3,321 wards, communes and special zones. It was reduced to codes and Vietnamese display names from the public [Province Open API v2](https://provinces.open-api.vn/api/v2/?depth=2) on 2026-11-06. The API is maintained by Nguyễn Hồng Quân: https://github.com/hongquan/vn-open-api-provinces.

The data is bundled so the location selectors work without an additional network request. Review and refresh this snapshot when administrative divisions change.

Location selectors are loaded on demand when their form opens. `vietnam-provinces.json` is a name-only index derived from the full snapshot for the Admin company directory, which does not need ward data. Regenerate both files together when refreshing the source.
