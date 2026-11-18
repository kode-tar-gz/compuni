# Compuni

Compuni is an utility package for GNU Emacs 29+ that provides commands to help insert unicode in emacs. Compuni aims to replace the slow and ugly built-in `insert-char` with fast, in-buffer unicode completion. It uses [company](https://company-mode.github.io/) as an ephemeral *(non-persistent)* UI frontend for the in-buffer drop-down menu of options; it does not persist in `company-backends` nor does it require the user to have `company-mode` stay enabled in the buffer.

Compuni provides two commands for inserting unicode:
* `compuni-insert-unicode`
* `compuni-insert-emoji`
Where the latter acts the exact same as the former, but filters out non-emoji symbols from the options. These functions should be bound to your prefered combination of keys to easily and effortlessly insert unicode and emojis in the active buffer. When one of these commands is used, it creates a cache of symbols and font heights to speed up subsequent calls. Thus, compuni also provides a `compuni-clear-cache` function to free up that space.

## Usage
Compuni isn't on any package repositories yet, so you gotta clone this repo and load it yourself.
Example configuration with `use-package`:
```elisp
(use-package compuni
  :ensure nil
  :load-path "/path/to/compuni"
  :after company
  :commands (compuni-insert-unicode compuni-insert-emoji)
  :bind (("C-c u u" . compuni-insert-unicode)
         ("C-c u e" . compuni-insert-emoji))
  :custom
  (compuni-max-candidates 50))
```

[https://github.com/user-attachments/assets/](https://github.com/user-attachments/assets/4bdfb2b1-e58a-459c-be42-6e9df9e99312)

## Customization
Compuni can be customized through these two variable:
* `compuni-max-candidates` : maximum number of candidates returned per query *(default: 50)*.
* `compuni-glyph-face` : face applied to glyphs in the left margin *(overrides company-tooltip-annotation foreground/style if customized)*.



**DISCLAIMER:** This package was made with lots of AI assistance. The tests were almost entirely written by an LLM and the main file was written with lots of assistance as well.
