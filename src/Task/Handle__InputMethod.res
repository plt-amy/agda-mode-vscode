open Belt

open! Task
// from Editor Command to Tasks
let handle = x =>
  switch x {
  | Command.InputMethod.Activate => list{
      WithStateP(
        state =>
          if EditorIM.isActivated(state.editorIM) {
            // already activated, insert backslash "\" instead
            EditorIM.insertBackslash(state.editor)
            EditorIM.deactivate(state.editorIM)
            Promise.resolved(list{ViewEvent(InputMethod(Deactivate))})
          } else {
            let document = VSCode.TextEditor.document(state.editor)
            // activated the input method with positions of cursors
            let startingRanges: array<(int, int)> =
              Editor.Selection.getMany(state.editor)->Array.map(range => (
                document->VSCode.TextDocument.offsetAt(VSCode.Range.start(range)),
                document->VSCode.TextDocument.offsetAt(VSCode.Range.end_(range)),
              ))
            EditorIM.activate(state.editorIM, state.editor, startingRanges)
            Promise.resolved(list{ViewEvent(InputMethod(Activate))})
          },
      ),
    }
  | PromptChange(input) => list{
      WithStateP(
        state => {
          // activate when the user typed a backslash "/"
          let shouldActivate = Js.String.endsWith("\\", input)

          let deactivateEditorIM = () => {
            EditorIM.deactivate(state.editorIM)
            list{ViewEvent(InputMethod(Deactivate))}
          }
          let activatePromptIM = () => {
            // remove the ending backslash "\"
            let input = Js.String.substring(~from=0, ~to_=String.length(input) - 1, input)
            PromptIM.activate(state.promptIM, input)

            // update the view
            list{ViewEvent(InputMethod(Activate)), ViewEvent(PromptIMUpdate(input))}
          }

          if EditorIM.isActivated(state.editorIM) {
            if shouldActivate {
              Promise.resolved(List.concatMany([deactivateEditorIM(), activatePromptIM()]))
            } else {
              Promise.resolved(list{ViewEvent(PromptIMUpdate(input))})
            }
          } else if PromptIM.isActivated(state.promptIM) {
            let result = PromptIM.update(state.promptIM, input)
            switch result {
            | None => Promise.resolved(list{DispatchCommand(InputMethod(Deactivate))})
            | Some((text, command)) =>
              Promise.resolved(list{
                ViewEvent(PromptIMUpdate(text)),
                DispatchCommand(InputMethod(command)),
              })
            }
          } else if shouldActivate {
            Promise.resolved(activatePromptIM())
          } else {
            Promise.resolved(list{ViewEvent(PromptIMUpdate(input))})
          }
        },
      ),
    }
  | Deactivate => list{
      WithState(
        state => {
          EditorIM.deactivate(state.editorIM)
          PromptIM.deactivate(state.promptIM)
        },
      ),
      ViewEvent(InputMethod(Deactivate)),
    }

  | Update(sequence, translation, index) => list{
      ViewEvent(InputMethod(Update(sequence, translation, index))),
    }
  | InsertChar(char) => list{
      WithStateP(
        state =>
          if EditorIM.isActivated(state.editorIM) {
            EditorIM.insertChar(state.editor, char)
            Promise.resolved(list{})
          } else if PromptIM.isActivated(state.promptIM) {
            let result = PromptIM.insertChar(state.promptIM, char)
            switch result {
            | None => Promise.resolved(list{DispatchCommand(InputMethod(Deactivate))})
            | Some((text, command)) =>
              Promise.resolved(list{
                ViewEvent(PromptIMUpdate(text)),
                DispatchCommand(InputMethod(command)),
              })
            }
          } else {
            Promise.resolved(list{})
          },
      ),
    }
  | ChooseSymbol(symbol) => list{
      WithStateP(
        state =>
          if EditorIM.isActivated(state.editorIM) {
            EditorIM.run(state.editorIM, state.editor, Candidate(ChooseSymbol(symbol)))
            ->Promise.map(EditorIM.fromOutput)
            ->Promise.map(x =>
              switch x {
              | None => list{}
              | Some(xs) => list{DispatchCommand(InputMethod(xs))}
              }
            )
          } else if PromptIM.isActivated(state.promptIM) {
            let result = PromptIM.chooseSymbol(state.promptIM, symbol)
            if result {
              Promise.resolved(list{ViewEvent(PromptIMUpdate(symbol))})
            } else {
              Promise.resolved(list{})
            }
          } else {
            Promise.resolved(list{})
          },
      ),
    }
  | MoveUp => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, state.editor, Candidate(BrowseUp))
          ->Promise.map(EditorIM.fromOutput)
          ->Promise.map(x =>
            switch x {
            | None => list{}
            | Some(xs) => list{DispatchCommand(InputMethod(xs))}
            }
          ),
      ),
    }
  | MoveRight => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, state.editor, Candidate(BrowseRight))
          ->Promise.map(EditorIM.fromOutput)
          ->Promise.map(x =>
            switch x {
            | None => list{}
            | Some(xs) => list{DispatchCommand(InputMethod(xs))}
            }
          ),
      ),
    }
  | MoveDown => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, state.editor, Candidate(BrowseDown))
          ->Promise.map(EditorIM.fromOutput)
          ->Promise.map(x =>
            switch x {
            | None => list{}
            | Some(xs) => list{DispatchCommand(InputMethod(xs))}
            }
          ),
      ),
    }
  | MoveLeft => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, state.editor, Candidate(BrowseLeft))
          ->Promise.map(EditorIM.fromOutput)
          ->Promise.map(x =>
            switch x {
            | None => list{}
            | Some(xs) => list{DispatchCommand(InputMethod(xs))}
            }
          ),
      ),
    }
  }
