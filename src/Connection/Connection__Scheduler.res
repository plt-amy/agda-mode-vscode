open Belt

// This module makes sure that Last Responses are handled after NonLast Responses
//
// There are 2 kinds of Responses
//  NonLast Response :
//    * get handled first
//    * don't invoke `sendAgdaRequest`
//  Last Response :
//    * have priorities, those with the smallest priority number are executed first
//    * only get handled:
//        1. after prompt has reappeared
//        2. after all NonLast Responses
//        3. after all interactive highlighting is complete
//    * may invoke `sendAgdaRequest`
module Module: {
  type t<'a>
  let make: unit => t<'a>
  let addLast: (t<'a>, int, Response.t) => unit
  let runNonLast: (t<'a>, Response.t => Promise.t<'a>, Response.t) => unit
  let runLast: (t<'a>, Response.t => Promise.t<'a>) => unit
} = {
  type t<'a> = {
    // keep the number of running NonLast Response
    mutable tally: int,
    allDone: Chan.t<unit>,
    deferredLastResponses: array<(int, Response.t)>,
  }
  let make = () => {
    tally: 0,
    allDone: Chan.make(),
    deferredLastResponses: [],
  }
  // NonLast Responses should fed here
  let runNonLast = (self, handler, response) => {
    // Js.log("[NonLast] " ++ Response.toString(response))
    self.tally = self.tally + 1
    handler(response)->Promise.get(_ => {
      self.tally = self.tally - 1
      if self.tally == 0 {
        self.allDone->Chan.emit()
      }
    })
  }
  // deferred (Last) Responses are queued here
  let addLast = (self, priority, response) => {
    // Js.log("[Add Last] " ++ string_of_int(priority) ++ " " ++ Response.toString(response))
    Js.Array.push((priority, response), self.deferredLastResponses)->ignore
  }
  // gets resolved once there's no NonLast Responses running
  let onceDone = self =>
    if self.tally == 0 {
      Promise.resolved()
    } else {
      self.allDone->Chan.once
    }
  // start handling Last Responses, after all NonLast Responses have been handled
  let runLast = (self, handler) =>
    self
    ->onceDone
    ->Promise.get(() => {
      // sort the deferred Responses by priority (ascending order)
      let deferredLastResponses =
        Js.Array.sortInPlaceWith(
          (x, y) => compare(fst(x), fst(y)),
          self.deferredLastResponses,
        )->Array.map(snd)

      // insert `CompleteHighlightingAndMakePromptReappear` after handling Last Responses
      Js.Array.unshift(
        Response.CompleteHighlightingAndMakePromptReappear,
        deferredLastResponses,
      )->ignore

      deferredLastResponses->Array.map(res => handler(res))->Util.oneByOne->ignore
    })
}

include Module
