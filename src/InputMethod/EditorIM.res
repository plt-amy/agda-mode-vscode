open Belt

type offset = int
type interval = (offset, offset)

module type Semaphore = {
  type t

  let make: unit => t
  let isLocked: t => bool
  let lock: t => unit
  let unlock: t => Promise.t<unit>
  let acquire: t => Promise.t<unit>
}
module Semaphore: Semaphore = {
  type t = ref<option<(Promise.t<unit>, unit => unit)>>

  let make = () => ref(None)

  let isLocked = self => self.contents->Option.isSome

  let lock = self => {
    let (promise, resolver) = Promise.pending()
    self.contents = Some(promise, resolver)
  }

  let unlock = self =>
    switch self.contents {
    | None => Promise.resolved()
    | Some((promise, resolver)) =>
      self.contents = None
      resolver()
      promise
    }

  let acquire = self =>
    switch self.contents {
    | None => Promise.resolved()
    | Some((promise, _)) => promise
    }
}

module type Temp = {
  // event => input
  let handleTextEditorSelectionChangeEvent: VSCode.TextEditorSelectionChangeEvent.t => array<
    VSCode.Position.t,
  >
  let handleTextDocumentChangeEvent: (
    VSCode.TextEditor.t,
    VSCode.TextDocumentChangeEvent.t,
  ) => array<Buffer.change>
}
module Temp: Temp = {
  // TextEditorSelectionChangeEvent.t => array<Position.t>
  let handleTextEditorSelectionChangeEvent = event =>
    event->VSCode.TextEditorSelectionChangeEvent.selections->Array.map(VSCode.Selection.anchor)

  let handleTextDocumentChangeEvent = (editor, event) => {
    // see if the change event happened in this TextEditor
    let fileName = editor->VSCode.TextEditor.document->VSCode.TextDocument.fileName
    let eventFileName = event->VSCode.TextDocumentChangeEvent.document->VSCode.TextDocument.fileName
    if fileName == eventFileName {
      // TextDocumentContentChangeEvent.t => Buffer.change
      event->VSCode.TextDocumentChangeEvent.contentChanges->Array.map(change => {
        Buffer.offset: change->VSCode.TextDocumentContentChangeEvent.rangeOffset,
        insertedText: change->VSCode.TextDocumentContentChangeEvent.text,
        replacedTextLength: change->VSCode.TextDocumentContentChangeEvent.rangeLength,
      })
    } else {
      []
    }
  }
}

module type Module = {
  // input
  type candidateInput =
    | ChooseSymbol(string)
    | BrowseUp
    | BrowseDown
    | BrowseLeft
    | BrowseRight
  type input =
    | Change(VSCode.TextDocumentChangeEvent.t)
    | Select(VSCode.TextEditorSelectionChangeEvent.t)
    | Candidate(candidateInput)

  // output
  type output =
    | Update(string, Translator.translation, int)
    | Activate
    | Deactivate

  type t

  let make: Chan.t<output> => t
  let activate: (t, VSCode.TextEditor.t, array<interval>) => unit
  let deactivate: t => unit
  let isActivated: t => bool
  let run: (t, VSCode.TextEditor.t, input) => Promise.t<option<Command.InputMethod.t>>

  let insertBackslash: VSCode.TextEditor.t => unit
  let insertChar: (VSCode.TextEditor.t, string) => unit
}
module Module: Module = {
  let printLog = true
  let log = if printLog {
    Js.log
  } else {
    _ => ()
  }

  // module type Instance = {
  //   type t

  //   // constructor/destructor
  //   let make: (VSCode.TextEditor.t, (int, int)) => t
  //   let destroy: t => unit
  //   // getters/setters
  //   let getRange: t => (int, int)
  //   let setRange: t => (int, int)

  //   // returns its range, for debugging
  //   let toString: t => string
  //   // see if an offset is with in its range
  //   let withIn: (t, int) => bool
  // }
  module Instance = {
    type t = {
      mutable interval: interval,
      mutable decoration: array<Editor.Decoration.t>,
      mutable buffer: Buffer.t,
    }

    let toString = self =>
      "(" ++ string_of_int(fst(self.interval)) ++ ", " ++ (string_of_int(snd(self.interval)) ++ ")")

    let make = (editor, interval) => {
      let document = VSCode.TextEditor.document(editor)
      let start = document->VSCode.TextDocument.positionAt(fst(interval))
      let end_ = document->VSCode.TextDocument.positionAt(snd(interval))
      {
        interval: interval,
        decoration: [Editor.Decoration.underlineText(editor, VSCode.Range.make(start, end_))],
        buffer: Buffer.make(),
      }
    }

    let withIn = (instance, offset) => {
      let (start, end_) = instance.interval
      start <= offset && offset <= end_
    }

    let redocorate = (instance, editor) => {
      instance.decoration->Array.forEach(Editor.Decoration.destroy)
      instance.decoration = []

      let document = VSCode.TextEditor.document(editor)
      let (start, end_) = instance.interval
      let start = document->VSCode.TextDocument.positionAt(start)
      let end_ = document->VSCode.TextDocument.positionAt(end_)
      let range = VSCode.Range.make(start, end_)

      instance.decoration = [Editor.Decoration.underlineText(editor, range)]
    }

    let destroy = instance => {
      instance.decoration->Array.forEach(Editor.Decoration.destroy)
      instance.decoration = []
    }
  }

  // input
  type candidateInput =
    | ChooseSymbol(string)
    | BrowseUp
    | BrowseDown
    | BrowseLeft
    | BrowseRight
  type input =
    | Change(VSCode.TextDocumentChangeEvent.t)
    | Select(VSCode.TextEditorSelectionChangeEvent.t)
    | Candidate(candidateInput)

  // output
  type output =
    | Update(string, Translator.translation, int)
    | Activate
    | Deactivate

  type t = {
    mutable instances: array<Instance.t>,
    mutable activated: bool,
    // cursor positions will NOT be validated until the semaphore `busy` is flipped false
    // cursor positions waiting to be validated will be queued here and resolved afterwards
    semaphore: Semaphore.t,
    // for reporting when some task has be done
    chanLog: Chan.t<output>,
  }

  // datatype for representing a rewrite to be made to the text editor
  type rewrite = {
    interval: interval,
    text: string,
    // `instance` has been destroyed if is None
    instance: option<Instance.t>,
  }

  // kill the Instances that are not are not pointed by cursors
  // returns `true` when the system should be Deactivate
  let validateCursorPositions = (self, document, points: array<VSCode.Position.t>) => {
    let offsets = points->Array.map(VSCode.TextDocument.offsetAt(document))
    log(
      "\n### Cursors  : " ++
      (Js.Array.sortInPlaceWith(compare, offsets)->Array.map(string_of_int)->Util.Pretty.array ++
      ("\n### Instances: " ++ self.instances->Array.map(Instance.toString)->Util.Pretty.array)),
    )

    // store the surviving instances
    self.instances = self.instances->Array.keep((instance: Instance.t) => {
        // if any cursor falls into the range of the instance, the instance survives
        let survived = offsets->Array.some(Instance.withIn(instance))
        // if not, the instance gets destroyed
        if !survived {
          Instance.destroy(instance)
        }
        survived
      })

    // return `true` and emit `Deactivate` if all instances have been destroyed
    // if Array.length(self.instances) == 0 {
    //   true
    // } else {
    //   false
    // }
  }

  //
  let toRewrites = (instances: array<Instance.t>, modify: Instance.t => option<string>): array<
    rewrite,
  > => {
    let accum = ref(0)

    instances->Array.keepMap(instance => {
      let (start, end_) = instance.interval

      // update the interval with `accum`
      instance.interval = (start + accum.contents, end_ + accum.contents)

      modify(instance)->Option.map(replacement => {
        let delta = String.length(replacement) - (end_ - start)
        // update `accum`
        accum := accum.contents + delta

        // update the interval with the change `delta`
        instance.interval = (fst(instance.interval), snd(instance.interval) + delta)

        // returns a `rewrite`
        {
          interval: instance.interval,
          text: replacement,
          instance: Some(instance),
        }
      })
    })
  }

  // iterate through a list of rewrites and apply them to the text editor
  let applyRewrites = (self, editor, rewrites) => {
    let document = VSCode.TextEditor.document(editor)

    // lock before applying edits to the text editor
    self.semaphore->Semaphore.lock

    // calculate the replacements to be made to the editor
    let replacements = rewrites->Array.map(({interval, text}) => {
      let editorRange = VSCode.Range.make(
        document->VSCode.TextDocument.positionAt(fst(interval)),
        document->VSCode.TextDocument.positionAt(snd(interval)),
      )
      (editorRange, text)
    })

    Editor.Text.batchReplace(document, replacements)->Promise.flatMap(_ => {
      // redecorate and update intervals of each Instance
      rewrites->Array.forEach(rewrite => {
        rewrite.instance->Option.forEach(instance => {
          Instance.redocorate(instance, editor)
        })
      })

      // all offsets updated and rewrites have been applied
      // unlock the semaphore
      self.semaphore->Semaphore.unlock
    })->Promise.map(_ => {
      // update the view
      self.instances[0]->Option.map(instance => {
        // for testing
        self.chanLog->Chan.emit(
          Update(
            Buffer.toSequence(instance.buffer),
            instance.buffer.translation,
            instance.buffer.candidateIndex,
          ),
        )
        // real output
        Command.InputMethod.Update(
          Buffer.toSequence(instance.buffer),
          instance.buffer.translation,
          instance.buffer.candidateIndex,
        )
      })
    })
  }

  let groupChangeWithInstances = (
    instances: array<Instance.t>,
    changes: array<Buffer.change>,
  ): array<(Instance.t, option<Buffer.change>)> => {
    // sort the changes base on their offsets in the ascending order
    let changes = Js.Array.sortInPlaceWith(
      (x: Buffer.change, y: Buffer.change) => compare(x.offset, y.offset),
      changes,
    )

    // iterate through Instances and changes
    // returns a list of Instances along with the changeEvent event that occurred inside that Instance
    let rec go: (
      int,
      (list<Buffer.change>, list<Instance.t>),
    ) => list<(Instance.t, option<Buffer.change>)> = (accum, x) =>
      switch x {
      | (list{change, ...cs}, list{instance, ...is}) =>
        let (start, end_) = instance.interval
        let delta = String.length(change.insertedText) - change.replacedTextLength
        if Instance.withIn(instance, change.offset) {
          // `change` appears inside the `instance`
          instance.interval = (accum + start, accum + end_ + delta)
          list{
            (instance, Some({...change, offset: change.offset + accum})),
            ...go(accum + delta, (cs, is)),
          }
        } else if change.offset < fst(instance.interval) {
          // `change` appears before the `instance`
          go(accum + delta, (cs, list{instance, ...is})) // update only `accum`
        } else {
          // `change` appears after the `instance`
          instance.interval = (accum + start, accum + end_)
          list{(instance, None), ...go(accum, (list{change, ...cs}, is))}
        }
      | (list{}, list{instance, ...is}) => list{instance, ...is}->List.map(i => (i, None))
      | (_, list{}) => list{}
      }
    go(0, (List.fromArray(changes), List.fromArray(instances)))->List.toArray
  }

  // update offsets of Instances base on changes
  let updateInstances = (instances: array<Instance.t>, changes: array<Buffer.change>): (
    array<Instance.t>,
    array<rewrite>,
  ) => {
    Js.log("CHANGE")
    let instancesWithChanges = groupChangeWithInstances(instances, changes)

    let rewrites = []

    // push rewrites to the `rewrites` queue
    let instances = {
      let accum = ref(0)
      instancesWithChanges->Array.keepMap(((instance, change)) =>
        switch change {
        | None => Some(instance)
        | Some(change) =>
          let (buffer, shouldRewrite) = Buffer.update(
            instance.buffer,
            fst(instance.interval),
            change,
          )
          // issue rewrites
          shouldRewrite->Option.forEach(text => {
            let (start, end_) = instance.interval
            let delta = String.length(text) - (end_ - start)

            // update the interval
            Js.log("update interval")
            instance.interval = (start + accum.contents, end_ + accum.contents + delta)
            Js.Array.push(
              {
                interval: (start + accum.contents, end_ + accum.contents),
                text: text,
                instance: buffer.translation.further ? Some(instance) : None,
              },
              rewrites,
            )->ignore
            accum := accum.contents + delta
          })

          // destroy the instance if there's no further possible transition
          if buffer.translation.further {
            instance.buffer = buffer
            Some(instance)
          } else {
            Instance.destroy(instance)
            None
          }
        }
      )
    }

    (instances, rewrites)
  }

  let activate = (self, editor, cursors: array<interval>) => {
    self.activated = true

    // emit ACTIVATE event after applied rewriting
    self.chanLog->Chan.emit(Activate)
    // setContext
    VSCode.Commands.setContext("agdaModeTyping", true)->ignore

    // instantiate from an array of offsets
    self.instances =
      Js.Array.sortInPlaceWith((x, y) => compare(fst(x), fst(y)), cursors)->Array.map(
        Instance.make(editor),
      )
  }

  let changeSelection = (self, editor, event) => {
    if self.activated {
      let positions = Temp.handleTextEditorSelectionChangeEvent(event)
      self.semaphore
      ->Semaphore.acquire
      ->Promise.tap(() =>
        validateCursorPositions(self, editor->VSCode.TextEditor.document, positions)
      )
      ->Promise.map(() =>
        if Js.Array.length(self.instances) == 0 {
          Some(Command.InputMethod.Deactivate)
        } else {
          None
        }
      )
    } else {
      Promise.resolved(None)
    }
  }

  let changeDocument = (self, editor, event) => {
    if self.activated && !Semaphore.isLocked(self.semaphore) {
      let changes = Temp.handleTextDocumentChangeEvent(editor, event)
      // update the offsets to reflect the changes
      let (instances, rewrites) = updateInstances(self.instances, changes)
      self.instances = instances
      // apply rewrites onto the text editor
      applyRewrites(self, editor, rewrites)
    } else {
      Promise.resolved(None)
    }
  }

  let deactivate = self => {
    // setContext
    VSCode.Commands.setContext("agdaModeTyping", false)->ignore

    Js.log2("DEACTIVATE from deactivate()", self.activated)
    self.chanLog->Chan.emit(Deactivate)
    self.instances->Array.forEach(Instance.destroy)
    self.instances = []
    self.activated = false
  }

  let make = chanLog => {
    let a = chanLog->Chan.on(Js.log2("output"))
    {
      instances: [],
      activated: false,
      semaphore: Semaphore.make(),
      chanLog: chanLog,
    }
  }
  ////////////////////////////////////////////////////////////////////////////////////////////

  let isActivated = self => self.activated

  // let onCommand = (self, callback) => self.chan->Chan.on(callback)

  let moveUp = (self, editor) => {
    let rewrites = toRewrites(self.instances, instance => {
      instance.buffer = Buffer.moveUp(instance.buffer)
      instance.buffer.translation.candidateSymbols[instance.buffer.candidateIndex]
    })
    // apply rewrites onto the text editor
    applyRewrites(self, editor, rewrites)
  }

  let moveRight = (self, editor) => {
    let rewrites = toRewrites(self.instances, instance => {
      instance.buffer = Buffer.moveRight(instance.buffer)
      instance.buffer.translation.candidateSymbols[instance.buffer.candidateIndex]
    })
    // apply rewrites onto the text editor
    applyRewrites(self, editor, rewrites)
  }

  let moveDown = (self, editor) => {
    let rewrites = toRewrites(self.instances, instance => {
      instance.buffer = Buffer.moveDown(instance.buffer)
      instance.buffer.translation.candidateSymbols[instance.buffer.candidateIndex]
    })

    // apply rewrites onto the text editor
    applyRewrites(self, editor, rewrites)
  }

  let moveLeft = (self, editor) => {
    let rewrites = toRewrites(self.instances, instance => {
      instance.buffer = Buffer.moveLeft(instance.buffer)
      instance.buffer.translation.candidateSymbols[instance.buffer.candidateIndex]
    })

    // apply rewrites onto the text editor
    applyRewrites(self, editor, rewrites)
  }

  let chooseSymbol = (self, editor, symbol) => {
    let rewrites = toRewrites(self.instances, _ => Some(symbol))
    // apply rewrites onto the text editor
    applyRewrites(self, editor, rewrites)
  }

  let run = (self, editor, input) => {
    switch input {
    | Select(event) => changeSelection(self, editor, event)
    | Change(event) => changeDocument(self, editor, event)
    | Candidate(ChooseSymbol(symbol)) => chooseSymbol(self, editor, symbol)
    | Candidate(BrowseUp) => moveUp(self, editor)
    | Candidate(BrowseDown) => moveDown(self, editor)
    | Candidate(BrowseLeft) => moveLeft(self, editor)
    | Candidate(BrowseRight) => moveRight(self, editor)
    }
  }

  let insertBackslash = editor =>
    Editor.Cursor.getMany(editor)->Array.forEach(point =>
      Editor.Text.insert(VSCode.TextEditor.document(editor), point, "\\")->ignore
    )
  let insertChar = (editor, char) => {
    let char = Js.String.charAt(0, char)
    Editor.Cursor.getMany(editor)->Array.forEach(point =>
      Editor.Text.insert(VSCode.TextEditor.document(editor), point, char)->ignore
    )
  }
}
include Module
