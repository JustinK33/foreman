"""Do the comments this change added earn their lines?

The rules are Stack Overflow's, all nine of them:
https://stackoverflow.blog/2021/12/23/best-practices-for-writing-code-comments/
Only some are visible in an edit payload, so only those are here:

    rule 1  a comment that duplicates the code
    rule 4  a comment that adds noise instead of dispelling confusion
    rule 9  is fine as written, so TODO and FIXME are left alone

Plus the two tells that are not in the article because a human writing at a
keyboard does not produce them: narrating the edit instead of the code, and
talking to the reader as though the file were a tutorial.

Rules 5 to 8 are the comments actually worth writing, and all four have the
same shape: they answer *why*. So any comment that reaches for a causal word,
a link, or an issue number is exempt outright, before any pattern below runs.
That one guard is what keeps this check from arguing with the good comments.

Line comments only. A docstring or a javadoc block has its own conventions,
where "Returns the parsed config." is correct and the same words on a bare
line are narration, so the scanner deliberately cannot see them.
"""

import re

# Per language, because `--count` in C and `#` inside a JS template string are
# not comments, and guessing wrong here means inventing a finding out of code.
LINE_COMMENT = {
    "#": (
        ".py", ".rb", ".sh", ".bash", ".zsh", ".pl", ".pm", ".jl", ".nim",
        ".ex", ".exs", ".r", ".tf", ".cr",
    ),
    "//": (
        ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".go", ".rs", ".java",
        ".kt", ".kts", ".swift", ".cs", ".fs", ".scala", ".c", ".cc", ".cpp",
        ".h", ".hpp", ".m", ".mm", ".php", ".dart", ".zig", ".groovy",
        ".vue", ".svelte",
    ),
    "--": (".lua", ".hs", ".sql", ".elm"),
    ";": (".clj", ".cljs", ".cljc", ".el"),
    "%": (".erl",),
}
TOKEN = {ext: token for token, exts in LINE_COMMENT.items() for ext in exts}

# A comment that answers "why" is the kind the article argues for, so it is
# exempt from everything else. Deliberately generous: the cost of exempting one
# clumsy comment is nothing, and the cost of nagging about a good one is that
# the whole check gets switched off.
WHY = re.compile(
    r"""(?ix)
      \b(?:
        because | since | so \s that | otherwise | reason | why
      | workaround | work \s ?around | bug | issue | broken | breaks | fails
      | crash(?:es)? | regress(?:ion|es)? | leaks?
      | intentional(?:ly)? | deliberate(?:ly)? | on \s purpose | by \s design
      | do \s not | don'?t | never | avoid | instead \s of | rather \s than
      | unlike | despite | prevents? | guards? | ensures?
      | assumes? | requires? | must | cannot | can'?t | won'?t | unless
      | depends? | relies | order \s matters
      | upstream | spec | rfc | cve | erratum | quirk
      | rate \s limit | race | deadlock | overflow | timeout
      | todo | fixme | hack | xxx | note: | warning: | safety: | perf:
      )\b
    | https?://                     # rule 6 and rule 7, done right
    | \b[A-Z][A-Z0-9]{1,9}-\d+\b    # JIRA-123
    | \#\d+                         # or a GitHub issue
    """
)

# Machine-readable directives. Not prose, not up for review.
PRAGMA = re.compile(
    r"""(?ix) ^ \s* (?:
        ! | -\*- | @? (?:
            noqa | type: | pyright | pylint | mypy | ruff | flake8 | pragma
          | eslint | prettier | biome | jshint | ts- | istanbul | c8 | v8
          | nolint | golangci | shellcheck | codespell | spdx | coding
          | region | endregion | global | sourcery | pyre | deprecated
        ) \b
    )"""
)

# Pure decoration, and the one-word labels that travel with it. A banner tells
# you where you already are; the declaration underneath says it better and
# cannot go stale.
BANNER = re.compile(
    r"""(?ix)
      ^ [\s=\-*~_\#/+.]* $                  # nothing but punctuation
    | ^ \s* [=\-*~_\#+]{3,}                 # ==== anything ====
    | ^ \s* step \s* \d+ \b
    | ^ \s* (?:
          imports? | includes? | requires? | dependencies
        | constants? | globals? | variables? | fields?
        | types? | interfaces? | classes? | enums?
        | (?: helper | utility | private | public | internal ) \s+
          (?: functions? | methods? | classes? )
        | functions? | methods? | helpers? | utils? | utilities
        | exports? | setup | teardown | cleanup | boilerplate
        | config(?:uration)? | initiali[sz]ation | declarations?
        | main (?: \s+ (?: function | entry \s* point | logic | body ) )?
      ) \s* [:=.\-]* \s* $
    """
)

# Narration of the edit rather than the code. git log already records this, and
# in six months the comment is the only one of the two that is wrong.
CHANGE_LOG = re.compile(
    r"""(?ix)
      ^ \s* (?:
          added | adding | updated? | updating | changed? | changing
        | removed? | removing | deleted? | refactored? | renamed?
        | moved? | replaced? | introduced? | implemented? | created?
        | bumped? | switched? | fixed \s (?:up|the \s formatting)
        | new \s+ (?: code | logic | version | helper | approach )
      ) \b
    | \b as \s+ (?: requested | discussed | agreed | per \s+ (?:the|your) ) \b
    | \b now \s+ (?: uses | returns | handles | supports | does | accepts | calls ) \b
    """
)

# The voice of a comment nobody re-read. None of these phrases survive contact
# with a reader who already knows the language.
FILLER = re.compile(
    r"""(?ix)
      \b it (?: '?s | \s is ) \s (?: important | worth ) \s
        (?: to \s note | noting | mentioning )
    | \b (?: please \s )? note \s that \b
    | \b as \s (?: you \s can \s see | we \s (?:can \s )? s(?:ee|aw) | mentioned ) \b
    | ^ \s* (?: here | now ) \s+ we \b
    | \b let'?s \s+ \w+
    | \b in \s+ (?: this | the \s+ following ) \s+
        (?: example | case | snippet | section | file | tutorial ) \b
    | \b for \s+ (?: clarity | completeness | readability | good \s measure ) \b
    | \b this \s+ (?: function | method | class | variable | line | block | file
                    | section | code | snippet ) \s+
        (?: is \s responsible \s for | simply | basically | essentially | just ) \b
    | \b (?: simply | basically | essentially | obviously | of \s course
            | needless \s to \s say ) \b
    | \b (?: feel \s free | make \s sure | keep \s in \s mind | remember ) \s+ to \b
    | \b (?: first | next | then | finally | lastly ) , \s
    | \b (?: we | you ) \s (?: can | will | need \s to | should | want \s to ) \s+ \w+
    | \b (?: that'?s \s it | all \s set | good \s to \s go | happy \s coding ) \b
    """
)

# Function words carry no information about the line either way.
STOPWORD = frozenset(
    """a an the this that these those to of for in on at by with from as is are
    was were be being been and or but not it its we our us you your i if then
    else do does did will would shall can could should may might must here there
    each every all any some no new up out into over when while than only also
    into per via about after before both
    through across along around against between within without upon until since
    during onto off down back again other such own more most very just same""".split()
)

# Verbs and nouns that describe what a line of code plainly does. A comment
# built only from these plus the identifiers already on the line is rule 1: it
# has said the code twice and will now go stale independently.
NARRATION = frozenset(
    """increment decrement set sets setting get gets getting return returns
    returning call calls calling create creates creating construct constructs
    initialize initializes initializing initialise initialises loop loops
    looping iterate iterates iterating check checks checking add adds adding
    remove removes removing append appends appending assign assigns assigned
    define defines defining declare declares import imports importing print
    prints log logs open opens close closes read reads write writes parse
    parses convert converts cast sort sorts filter filters count counts update
    updates delete deletes save saves load loads start starts stop stops run
    runs execute executes handle handles process processes validate validates
    format formats build builds make makes send sends fetch fetches store
    stores stored clear clears reset resets wrap wraps hold holds holding
    contain contains containing instance value values variable variables
    function method class object list dict array map string number result
    results temp temporary helper flag placeholder field property attribute
    param parameter parameters argument arguments constructor getter setter
    then done first second third next last
    file files path paths data item items key keys index entry entries row rows
    line lines text content contents name names size length copy default"""
    .split()
)

# Markdown and prose inside a triple-quoted string or a template literal, which
# is the one place a "## Imports" line is not a comment at all. Prompt
# templates and fixture blobs are full of them, and without this the scanner
# reviews their headings as though they were code comments.
FENCE = {"#": ('"""', "'''"), "//": ("`",), "--": ("[[",)}

# One clumsy comment is a style opinion. Several in one change is a habit, and
# the habit is what the nudge is about.
MIN_FINDINGS = 2
# How many to quote before summarising.
NAMED = 3
# Under this many informative words there is nothing to judge: "# fallthrough"
# is a label, not a description, even when it repeats the line below it.
MIN_WORDS = 2


def comment_at(line, token):
    """Split a line into (code, comment body), or None if it has no comment.

    Not a parser. A token is only a comment when it starts the line or follows
    whitespace and the quotes before it balance, which rejects "https://x" and
    f"{x}#{y}" and accepts everything that actually occurs. A quote inside a
    comment defeats it, and the cost of that is one missed finding.
    """
    start = 0
    while True:
        at = line.find(token, start)
        if at < 0:
            return None
        before = line[:at]
        if (
            (not before or before[-1].isspace())
            and before.count('"') % 2 == 0
            and before.count("'") % 2 == 0
        ):
            return before, line[at + len(token):]
        start = at + 1


def is_doc_comment(token, body):
    """/// and //! and #' and -- | are documentation, not commentary.

    Python docstrings and javadoc blocks never reach here at all: neither holds
    a line-comment token, so the scanner cannot see them in the first place.
    """
    lead = body.lstrip()[:1]
    return bool(body) and (
        (token == "//" and body[0] in "/!")
        or (token == "#" and body[0] == "'")
        or (token == "--" and (body[0] == "[" or lead == "|"))
    )


def parts(identifier):
    """spotPriceUsd -> spot, price, usd. So a comment that repeats an
    identifier in prose still counts as repeating it."""
    return [p.lower() for p in re.split(r"_+|(?<=[a-z0-9])(?=[A-Z])", identifier) if p]


def code_words(code):
    words = set()
    for identifier in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", code):
        words.add(identifier.lower())
        words.update(parts(identifier))
    return words


def duplicates(body, code):
    """Rule 1: does the comment say anything the code next to it does not?

    Every word has to be either an identifier already on that line or a verb
    that describes what any line does. One word the code does not contain is
    enough to keep the comment, which is the direction to be wrong in.
    """
    if not code.strip():
        return False
    said = [w for w in (w.lower() for w in re.findall(r"[A-Za-z]+", body)) if w not in STOPWORD]
    if len(said) < MIN_WORDS:
        return False
    known = code_words(code)
    return all(
        word in NARRATION
        or word in known
        or word.rstrip("s") in known
        or word + "s" in known
        for word in said
    )


def reason(body, code):
    """What is wrong with this comment, or None if nothing is.

    Ordered by how sure the answer is. A banner is a banner whatever sits
    under it; restating the code is the judgement call, so it goes last.
    """
    if BANNER.match(body):
        return "labels a section the code already declares"
    if CHANGE_LOG.search(body):
        return "recaps the edit, which is the commit message's job"
    if FILLER.search(body):
        return "addresses the reader instead of explaining the code"
    if duplicates(body, code):
        return "restates the code next to it"
    return None


def next_code_line(lines, start, token):
    """The line a standalone comment is describing: the next one with code on
    it. Comments in between belong to the same block and describe it too."""
    for line in lines[start:]:
        split = comment_at(line, token)
        head = line if split is None else split[0]
        if head.strip():
            return head
    return ""


def findings(text, extension):
    """(line number, comment, what is wrong with it) for one blob of added text.

    Line numbers are relative to the text given, not to the file: an Edit's
    payload does not say where its new_string lands.
    """
    token = TOKEN.get(extension)
    if not token:
        return []

    lines = text.split("\n")
    fences = FENCE.get(token, ())
    in_string = False
    found = []
    for number, line in enumerate(lines, 1):
        if fences:
            opened = in_string
            # An odd number of fences on a line means it ended on the other side
            # of one. A line that opens a string and then holds prose is missed,
            # which costs one finding and never invents one.
            if sum(line.count(fence) for fence in fences) % 2:
                in_string = not in_string
            if opened:
                continue
        split = comment_at(line, token)
        if not split:
            continue
        code, body = split
        if is_doc_comment(token, body) or PRAGMA.search(body):
            continue
        stripped = body.strip()
        if not stripped or WHY.search(stripped):
            continue

        # A trailing comment describes its own line. A standalone one describes
        # whatever comes next.
        if not code.strip():
            code = next_code_line(lines, number, token)

        wrong = reason(body, code)
        if wrong:
            found.append((number, stripped, wrong))
    return found


def note(path, found):
    """The nudge, or "" when there is not enough to say anything about.

    Assembled here rather than in the hook so the message sits next to the
    rules it is citing, and goes stale with them.
    """
    if len(found) < MIN_FINDINGS:
        return ""
    shown = "; ".join(f'"{body}" ({why})' for _, body, why in found[:NAMED])
    if len(found) > NAMED:
        shown += f", and {len(found) - NAMED} more"
    return (
        f"{len(found)} comments this change added to {path} read as narration rather "
        f"than explanation: {shown}. Rewrite them the way a person reviewing this file "
        "would want them: keep only what the code cannot say itself, which is why this "
        "approach and not the obvious one, what breaks if it changes, and a link to the "
        "source or the issue. Delete the rest rather than rewording them. "
        "https://stackoverflow.blog/2021/12/23/best-practices-for-writing-code-comments/"
    )
