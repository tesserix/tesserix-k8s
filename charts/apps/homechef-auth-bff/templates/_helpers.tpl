{{/*
homechef-auth-bff has no shared template helpers right now. mark8ly's helper
defines a DB env block; the homechef auth-bff does not talk to a database
(Zitadel issues tokens, session lives in an encrypted cookie, OpenFGA is not
wired in slice 1), so there is nothing to share. Kept as a marker file so
the chart layout matches mark8ly-auth-bff.
*/}}
