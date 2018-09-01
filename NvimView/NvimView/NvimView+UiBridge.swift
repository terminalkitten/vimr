/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import RxNeovimApi
import RxSwift
import MessagePack

extension NvimView {

  final func resize(_ value: MessagePackValue) {
    guard let array = MessagePackUtils.array(from: value, ofSize: 2, conversion: { $0.intValue }) else {
      return
    }

    bridgeLogger.debug("\(array[0]) x \(array[1])")
    gui.async {
      self.ugrid.resize(Size(width: array[0], height: array[1]))
//      self.markForRenderWholeView()
    }
  }

  final func clear() {
    bridgeLogger.mark()

    gui.async {
      self.ugrid.clear()
      self.markForRenderWholeView()
    }
  }

  final func modeChange(_ value: MessagePackValue) {
    guard let mode = MessagePackUtils.value(from: value, conversion: { v -> CursorModeShape? in
      guard let rawValue = v.intValue else { return nil }
      return CursorModeShape(rawValue: UInt(rawValue))
    }) else { return }

    bridgeLogger.debug(name(of: mode))
    gui.async {
      self.mode = mode
    }
  }

  final func scroll(_ value: MessagePackValue) {
    guard let array = MessagePackUtils.array(
      from: value, ofSize: 6, conversion: { $0.intValue }
    ) else {
      bridgeLogger.error("The data did not have required 6 Int's!")
      return
    }

    stdoutLogger.debug("[top, bot, left, right, rows, cols] = \(array)")

    let (top, bottom, left, right, row, column)
      = (array[0], array[1] - 1, array[2], array[3] - 1, array[4], array[5])
    let scrollRegion = Region(
      top: top, bottom: bottom,
      left: left, right: right
    )
    let scrollRect = self.rect(for: scrollRegion)
    let maxBottom = self.ugrid.size.height - 1
    let regionToRender = Region(
      top: min(max(0, top - row), maxBottom),
      bottom: max(0, min(bottom - row, maxBottom)),
      left: left, right: right
    )
    let rectToRender = self.rect(for: regionToRender)
    stdoutLogger.debug("region to render: \(regionToRender)")

    gui.async {
      self.ugrid.scroll(region: scrollRegion, rows: row, cols: column)

      guard let bufferContext = self.bufferContext,
            let bufferLayer = self.bufferLayer
        else {
        stdoutLogger.error("No context!")
        return
      }

      let scrollTargetRect = CGRect(
        x: 0,
        y: self.yOffset + self.cellSize.height * CGFloat(row),
        width: self.bounds.width,
        height: self.bounds.height
      )
      bufferContext.clip(to: rectToRender)
      bufferContext.draw(bufferLayer, in: scrollTargetRect)
      bufferContext.resetClip()

      // We want to re-use the already-drawn content of the buffer.
      self.markForRenderWithoutClearingBuffer(rect: scrollRect)

      self.eventsSubject.onNext(.scroll)
    }
  }

  final func unmark(_ value: MessagePackValue) {
//    bridgeLogger.debug("\(row):\(column)")
//
//    gui.async {
//      let position = Position(row: row, column: column)
//
//      self.grid.unmarkCell(position)
//      self.markForRender(position: position)
//    }
  }

  final func flush(_ renderData: [MessagePackValue]) {
//    bridgeLogger.hr()
    stdoutLogger.debug(renderData.count)

    gui.async {
      renderData.forEach { value in
        guard let renderEntry = value.arrayValue else { return }
        guard renderEntry.count == 2 else { return }

        guard let rawType = renderEntry[0].intValue,
              let innerArray = renderEntry[1].arrayValue,
              let type = RenderDataType(rawValue: rawType) else { return }

        switch type {

        case .rawLine:
          self.doRawLine(data: innerArray)

        case .goto:
          guard let row = innerArray[0].unsignedIntegerValue,
                let col = innerArray[1].unsignedIntegerValue else { return }

          self.doGoto(position: Position(row: Int(row), column: Int(col)))

        }
      }

      // The position stays at the first cell when we enter the terminal mode and the cursor seems to be drawn by
      // changing the background color of the corresponding cell...
      if self.mode != .termFocus {
        self.shouldDrawCursor = true
      }
    }
  }

  final func setTitle(with value: MessagePackValue) {
    guard let title = value.stringValue else { return }

    bridgeLogger.debug(title)
    self.eventsSubject.onNext(.setTitle(title))
  }

  final func stop() {
    bridgeLogger.hr()
    try? self.api
      .stop()
      .andThen(self.bridge.quit())
      .andThen(Completable.create { completable in
        self.eventsSubject.onNext(.neoVimStopped)
        self.eventsSubject.onCompleted()

        completable(.completed)
        return Disposables.create()
      })
      .observeOn(MainScheduler.instance)
      .wait()
  }

  final func autoCommandEvent(_ value: MessagePackValue) {
    guard let array = MessagePackUtils.array(from: value, ofSize: 2, conversion: { $0.intValue }),
          let event = NvimAutoCommandEvent(rawValue: array[0]) else { return }
    let bufferHandle = array[1]

    bridgeLogger.debug("\(event) -> \(bufferHandle)")

    if event == .bufwinenter || event == .bufwinleave {
      self.bufferListChanged()
    }

    if event == .tabenter {
      self.eventsSubject.onNext(.tabChanged)
    }

    if event == .bufwritepost {
      self.bufferWritten(bufferHandle)
    }

    if event == .bufenter {
      self.newCurrentBuffer(bufferHandle)
    }
  }

  final func ipcBecameInvalid(_ reason: String) {
    bridgeLogger.debug(reason)

    self.eventsSubject.onNext(.ipcBecameInvalid(reason))
    self.eventsSubject.onCompleted()

    bridgeLogger.error("Force-closing due to IPC error.")
    try? self.api
      .stop()
      .andThen(self.bridge.forceQuit())
      .observeOn(MainScheduler.instance)
      .wait()
  }

  private func doRawLine(data: [MessagePackValue]) {
    guard data.count == 7 else {
      stdoutLogger.error(
        "Data has wrong number of elements: \(data.count) instead of 7"
      )
      return
    }

    guard let row = data[0].intValue,
          let startCol = data[1].intValue,
          let endCol = data[2].intValue, // past last index, but can be 0
          let clearCol = data[3].intValue, // past last index (can be 0?)
          let clearAttr = data[4].intValue,
          let chunk = data[5].arrayValue?.compactMap({ $0.stringValue }),
          let attrIds = data[6].arrayValue?.compactMap({ $0.intValue })
      else {

      stdoutLogger.error("Values could not be read from: \(data)")
      return
    }

//    bridgeLogger.debug(
//      "row: \(row), startCol: \(startCol), endCol: \(endCol), " +
//        "chunk: \(chunk.reduce("") { $0 + $1 }.trimmingCharacters(in: .whitespacesAndNewlines))"
//    )

    let count = endCol - startCol
    guard chunk.count == count && attrIds.count == count else {
      stdoutLogger.error("The counts of chunk and attrIds do not match!")
      return
    }
    self.ugrid.update(row: row,
                      startCol: startCol,
                      endCol: endCol,
                      clearCol: clearCol,
                      clearAttr: clearAttr,
                      chunk: chunk,
                      attrIds: attrIds)

    var dirtyRects = Array<CGRect>()
    dirtyRects.reserveCapacity(2)
    var dirtyRegion = Array<Region>()
    dirtyRegion.reserveCapacity(2)

    if endCol > startCol {
      if self.usesLigatures {

        let leftBoundary = self.ugrid.leftBoundaryOfWord(
          at: Position(row: row, column: startCol)
        )
        let rightBoundary = self.ugrid.rightBoundaryOfWord(
          at: Position(row: row, column: max(0, endCol - 1))
        )

        let region = Region(
          top: row, bottom: row, left: leftBoundary, right: rightBoundary
        )
        let rect = self.rect(for: region)

        dirtyRects.append(rect)
        dirtyRegion.append(region)
        self.markForRender(rect: rect)

      } else {

        let region = Region(
          top: row, bottom: row, left: startCol, right: max(0, endCol - 1)
        )
        let rect = self.rect(for: region)

        dirtyRects.append(rect)
        dirtyRegion.append(region)
        self.markForRender(rect: rect)

      }
    }

    if clearCol > endCol {
      let region = Region(
        top: row, bottom: row, left: endCol, right: max(endCol, clearCol - 1)
      )
      let rect = self.rect(for: region)

      dirtyRects.append(rect)
      dirtyRegion.append(region)
      self.markForRender(rect: rect)
    }

    let attrsRuns = self.runs(intersecting: dirtyRects)

    let runs = attrsRuns.parallelMap {
      run -> (attrsRun: AttributesRun, fontGlyphRuns: [FontGlyphRun]) in

      let font = FontUtils.font(adding: run.attrs.fontTrait, to: self.font)

      let fontGlyphRuns = self.typesetter.fontGlyphRunsWithLigatures(
        nvimUtf16Cells: run.cells.map { Array($0.string.utf16) },
        startColumn: run.cells.startIndex,
        offset: CGPoint(
          x: self.xOffset, y: run.location.y + self.baselineOffset
        ),
        font: font,
        cellWidth: self.cellSize.width
      )

      return (attrsRun: run, fontGlyphRuns: fontGlyphRuns)
    }

    guard let context = self.bufferContext else {
      stdoutLogger.error("No context!")
      return
    }

    let defaultAttrs = self.cellAttributesCollection.defaultAttributes

    context.setFillColor(
      ColorUtils.cgColorIgnoringAlpha(defaultAttrs.background)
    )
    context.fill(dirtyRects)

    runs.forEach { (attrsRun, fontGlyphRuns) in
      self.runDrawer.draw(
        attrsRun,
        fontGlyphRuns: fontGlyphRuns,
        defaultAttributes: defaultAttrs,
        in: context
      )
    }
  }

  private func doGoto(position: Position) {
//    bridgeLogger.debug(position)

//    self.markForRender(cellPosition: self.grid.position)
//    self.grid.goto(position)
  }
}

// MARK: - Simple
extension NvimView {

  final func bell() {
    bridgeLogger.mark()

    NSSound.beep()
  }

  final func cwdChanged(_ value: MessagePackValue) {
    guard let cwd = value.stringValue else { return }

    bridgeLogger.debug(cwd)
    self._cwd = URL(fileURLWithPath: cwd)
    self.eventsSubject.onNext(.cwdChanged)
  }

  final func colorSchemeChanged(_ value: MessagePackValue) {
    guard let values = MessagePackUtils.array(from: value, ofSize: 5, conversion: { $0.intValue }) else { return }

    let theme = Theme(values)
    bridgeLogger.debug(theme)

    gui.async {
      self.theme = theme
      self.eventsSubject.onNext(.colorschemeChanged(theme))
    }
  }

  final func defaultColorsChanged(_ value: MessagePackValue) {
    guard let values = MessagePackUtils.array(
      from: value, ofSize: 3, conversion: { $0.intValue }
    ) else {
      return
    }

    bridgeLogger.trace(values)

    let attrs = CellAttributes(
      fontTrait: [],
      foreground: values[0],
      background: values[1],
      special: values[2],
      reverse: false
    )
    gui.async {
      self.cellAttributesCollection.set(
        attributes: attrs,
        for: CellAttributesCollection.defaultAttributesId
      )
      self.layer?.backgroundColor = ColorUtils.cgColorIgnoringAlpha(
        attrs.background
      )
    }
  }

  final func setDirty(with value: MessagePackValue) {
    guard let dirty = value.boolValue else { return }

    bridgeLogger.debug(dirty)
    self.eventsSubject.onNext(.setDirtyStatus(dirty))
  }

  final func setAttr(with value: MessagePackValue) {
    guard let array = value.arrayValue else { return }
    guard array.count == 6 else { return }

    guard let id = array[0].intValue,
          let rawTrait = array[1].unsignedIntegerValue,
          let fg = array[2].intValue,
          let bg = array[3].intValue,
          let sp = array[4].intValue,
          let reverse = array[5].boolValue
      else {

      bridgeLogger.error("Could not get highlight attributes from " +
                           "\(value)")
      return
    }
    let trait = FontTrait(rawValue: UInt(rawTrait))

    let attrs = CellAttributes(
      fontTrait: trait,
      foreground: fg,
      background: bg,
      special: sp,
      reverse: reverse
    )

    bridgeLogger.trace("\(id) -> \(attrs)")

    gui.async {
      self.cellAttributesCollection.set(attributes: attrs, for: id)
    }
  }

  final func updateMenu() {
    bridgeLogger.mark()
  }

  final func busyStart() {
    bridgeLogger.mark()
  }

  final func busyStop() {
    bridgeLogger.mark()
  }

  final func mouseOn() {
    bridgeLogger.mark()
  }

  final func mouseOff() {
    bridgeLogger.mark()
  }

  final func visualBell() {
    bridgeLogger.mark()
  }

  final func suspend() {
    bridgeLogger.mark()
  }
}

extension NvimView {

  final func markForRender(cellPosition position: Position) {
    self.markForRender(position: position)

    if self.grid.isCellEmpty(position) {
      self.markForRender(position: self.grid.previousCellPosition(position))
    }

    if self.grid.isNextCellEmpty(position) {
      self.markForRender(position: self.grid.nextCellPosition(position))
    }
  }

  final func markForRender(position: Position) {
    self.markForRender(row: position.row, column: position.column)
  }

  final func markForRender(screenCursor position: Position) {
    self.markForRender(position: position)
    if self.grid.isNextCellEmpty(position) {
      self.markForRender(position: self.grid.nextCellPosition(position))
    }
  }

  final func markForRender(region: Region) {
    self.markForRender(rect: self.rect(for: region))
  }

  final func markForRender(row: Int, column: Int) {
    self.markForRender(rect: self.rect(forRow: row, column: column))
  }

  final func markForRenderWholeView() {
    self.needsDisplay = true
    self.bufferContext?.clear(CGRect(origin: .zero, size: self.bounds.size))
  }

  private func markForRender(rect: CGRect) {
    self.setNeedsDisplay(rect)
    self.bufferContext?.clear(rect)
  }

  private func markForRenderWithoutClearingBuffer(rect: CGRect) {
    self.setNeedsDisplay(rect)
  }
}

extension NvimView {

  private func bufferWritten(_ handle: Int) {
    self
      .currentBuffer()
      .flatMap { curBuf -> Single<NvimView.Buffer> in
        self.neoVimBuffer(for: Api.Buffer(handle), currentBuffer: curBuf.apiBuffer)
      }
      .subscribe(onSuccess: {
        self.eventsSubject.onNext(.bufferWritten($0))
        if #available(OSX 10.12.2, *) {
          self.updateTouchBarTab()
        }
      }, onError: { error in
        self.eventsSubject.onNext(.apiError(msg: "Could not get the buffer \(handle).", cause: error))
      })
  }

  private func newCurrentBuffer(_ handle: Int) {
    self
      .currentBuffer()
      .filter { $0.apiBuffer.handle == handle }
      .subscribe(onSuccess: {
        self.eventsSubject.onNext(.newCurrentBuffer($0))
        if #available(OSX 10.12.2, *) {
          self.updateTouchBarTab()
        }
      }, onError: { error in
        self.eventsSubject.onNext(.apiError(msg: "Could not get the current buffer.", cause: error))
      })
  }

  private func bufferListChanged() {
    self.eventsSubject.onNext(.bufferListChanged)
    if #available(OSX 10.12.2, *) {
      self.updateTouchBarCurrentBuffer()
    }
  }
}

private let gui = DispatchQueue.main

private func name(of mode: CursorModeShape) -> String {
  switch mode {
    // @formatter:off
    case .normal:                  return "Normal"
    case .visual:                  return "Visual"
    case .insert:                  return "Insert"
    case .replace:                 return "Replace"
    case .cmdline:                 return "Cmdline"
    case .cmdlineInsert:           return "CmdlineInsert"
    case .cmdlineReplace:          return "CmdlineReplace"
    case .operatorPending:         return "OperatorPending"
    case .visualExclusive:         return "VisualExclusive"
    case .onCmdline:               return "OnCmdline"
    case .onStatusLine:            return "OnStatusLine"
    case .draggingStatusLine:      return "DraggingStatusLine"
    case .onVerticalSepLine:       return "OnVerticalSepLine"
    case .draggingVerticalSepLine: return "DraggingVerticalSepLine"
    case .more:                    return "More"
    case .moreLastLine:            return "MoreLastLine"
    case .showingMatchingParen:    return "ShowingMatchingParen"
    case .termFocus:               return "TermFocus"
    case .count:                   return "Count"
    // @formatter:on
  }
}
