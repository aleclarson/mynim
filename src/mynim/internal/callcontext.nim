## Package callcontext holds the keys of what package mynim puts in the
## context of calls for the official plugins.

type PageKey* = object
  ## The key of the Done channel of the calling page's context, which
  ## navigating or closing the window replaces, unlike the page.
