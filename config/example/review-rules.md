Review rules for an epic branch. Flag only these; anything else is a note at most.
- blocker: a file outside the ticket's owned paths was changed.
- blocker: an existing test deleted, disabled or its assertion weakened, unless the ticket asks for exactly that.
- blocker: credential or key material committed anywhere: `.env` files, keys, tokens or passwords in code or config.
- blocker: code in one project imports from or reaches by path into another project's tree.
- blocker: an already-applied database migration edited in place.
- blocker: a command with a production target written into code, a script or a workflow.
- warning: a dependency added or changed without its lockfile in the same change.
- warning: a document moved or deleted while a code comment still cites the old path.
