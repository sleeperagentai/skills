# Ranking

`search.py` tokenizes the query (lowercase, split on non-alphanumerics, drop stopwords such as
"how do i", "skill", "for", "make", crude stemming of -s/-es/-ed/-ing). Every query token that
occurs anywhere in the catalog gets an IDF weight (log(1 + N/df)), so rare words such as
"remotion" count far more than common ones such as "code".

For each entry a token earns IDF times the best field it hits:

| Field | Weight |
|---|---|
| name | 12 |
| aliases | 12 |
| tags | 8 |
| description | 5 |
| category key or label | 4 |
| fuzzy hit (same first letter, similarity >= 0.8) | 60% of the field weight |

The sum is divided by the best possible sum for that query (every token hitting a name) and
scaled to 0-100. Bonuses: exact name match +30, a `triggers` phrase in the query +15, the whole
query verbatim in the description +10. Capped at 100. Ties: vendored skills before collections and
plugins, then alphabetical.

## Reading the output

- `>= 60` strong: present as the answer.
- `40 to 59` plausible: present, but offer the ecosystem search as well.
- `< 40` or exit 3: treat as "not in catalog" and go to the internet path, after one retry with a
  shorter, noun-only query (for example "landing page copy" instead of "help me write the words on
  my landing page").

`matched_on` in the JSON output lists which signals fired (`name:test`, `tag~nextj`, `trigger:…`).
Pass `--explain` to see them in the table. Use it to explain a recommendation in one phrase ("matched on tags design, anti-slop").

## Broadening or narrowing

- `--category design` restricts skills to one category (collections and plugins still show).
- `--kinds skill` hides collections and plugins.
- `--min-score 5` shows weak matches when you want to see what is close.
- `--top 10` when the user wants a menu rather than a recommendation.
