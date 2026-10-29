DRAGON NET mirror (Cloudflare Worker)
=====================================

For players who can't reach the ranked server at all (their antivirus web protection, router
security or ISP blocks its free-hosting address: the launcher says "The secure connection to
DRAGON NET was refused on the way", and the site doesn't open in their browser either).

The worker passes every request on to the real server, so nothing moves and there's one
database. Launchers try the server first and switch to the mirror by themselves when the server
can't be reached ([ranked] mirror in frontend.cfg; the launcher's default once it's set there).

Set up (free plan is enough: 100,000 requests a day)
------------------------------------------------------
1. dash.cloudflare.com > Workers & Pages > Create > Create Worker. Name it e.g. "dragonnet"
   > Deploy. Its address: https://dragonnet.<your-subdomain>.workers.dev
2. Edit code: replace everything with worker.js (this folder) > Deploy.
3. Settings > Variables and Secrets:
     ORIGIN     (Text)    https://tecshideout.ct.ws
     PROXY_KEY  (Secret)  a long random password (20+ characters)
   > Deploy.
4. config.php on the server: add the same password:
     'proxy_key' => '<the PROXY_KEY>',
   (with it the server sees mirror players' own addresses for login limits, and links and
   pictures it hands out point at the mirror).
5. Check: open https://dragonnet.<your-subdomain>.workers.dev/sparking/ : the site, as usual.
6. Tell me (or set it yourself in Frontend/Godot/scripts/settings.gd, "ranked" > "mirror") the
   address https://dragonnet.<your-subdomain>.workers.dev/sparking/ and ship a launcher update.
   Until then, a blocked player can put it in their frontend.cfg:
     [ranked]
     mirror="https://dragonnet.<your-subdomain>.workers.dev/sparking/"

Your own domain (later): Workers > the worker > Settings > Domains & Routes > Add a custom
domain (the domain must be on Cloudflare). Then use that address as the mirror (or as the
server itself).

Not through the mirror: the Discord login for old ranked profiles (its redirect address is
the server's, set in config.php and Discord's Developer Portal).
