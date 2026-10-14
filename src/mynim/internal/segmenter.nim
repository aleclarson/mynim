## Port of github.com/go-text/typesetting/segmenter (v0.3.5).
## Unicode text segmentation: UAX #29 grapheme/word boundaries and
## UAX #14 line break opportunities.

import unicode
import ucd

type breakAttr = uint8

const
  lineBoundary* = breakAttr(1 shl 0)
  mandatoryLineBoundary* = breakAttr(1 shl 1)
  graphemeBoundary* = breakAttr(1 shl 2)
  wordBoundary* = breakAttr(1 shl 3)

const paragraphSeparator = Rune(0x2029)

proc runeByteLen(r: Rune): int =
  ## utf8.RuneLen: bytes needed to encode r, or 0 if invalid.
  let i = int32(r)
  if i < 0 or i > 0x10FFFF: return 0
  if i < 0x80: 1
  elif i < 0x800: 2
  elif i < 0x10000: 3
  else: 4

type
  numSequenceState = uint8
  pictoSequenceState = uint8
  indicCBSequenceState = uint8
  breakOpportunity = uint8
  cursor = object
    index, len: int
    isPreviousSot: bool
    prevPrev, prev, r, next: Rune
    isExtentedPic: bool
    prevGeneralCategory, generalCategory: GeneralCategory
    prevGrapheme, grapheme: GraphemeBreak
    isPrevGraphemeRIOdd: bool
    prevPrevWord, prevWord, word: WordBreak
    prevWordNoExtend: int
    isPrevWordRIOdd: bool
    prevPrevLine, prevLine, prevLineRaw, line, nextLine: LineBreak
    isPrevPrevDottedCircle, isPrevDottedCircle: bool
    isPrevNonAssignedExtendedPic: bool
    prevBeforeSpaces, beforeSpaces: Rune
    prevBeforeSpacesLine, beforeSpacesLine: LineBreak
    beforeSpaceLineRaw: LineBreak
    beforeSpacesIndex: int
    isPrevLinebreakRIOdd: bool
    indicConjunctBreak: IndicConjunctBreak
    numSequence: numSequenceState
    pictoSequence: pictoSequenceState
    indicConjunctBreakSequence: indicCBSequenceState

const
  noNumSequence* = numSequenceState(0)
  inNumSequence* = numSequenceState(1)
  seenCloseNum* = numSequenceState(2)
  noPictoSequence* = pictoSequenceState(0)
  inPictoExtend* = pictoSequenceState(1)
  seenPictoZWJ* = pictoSequenceState(2)
  noIndicCBSequence* = indicCBSequenceState(0)
  inIndicCBSequence* = indicCBSequenceState(1)
  seenIndicCBSequence* = indicCBSequenceState(2)
  breakEmpty* = breakOpportunity(0)
  breakProhibited* = breakOpportunity(1)
  breakAllowed* = breakOpportunity(2)
  breakMandatory* = breakOpportunity(3)

# --------------------- Grapheme boundaries (UAX #29) ---------------------

proc updateGraphemeRIOdd(cr: var cursor): bool =
  if cr.grapheme == GB_Regional_Indicator:
    result = cr.isPrevGraphemeRIOdd
    cr.isPrevGraphemeRIOdd = not cr.isPrevGraphemeRIOdd
  else:
    cr.isPrevGraphemeRIOdd = false

proc updatePictoSequence(cr: var cursor): bool =
  case cr.pictoSequence
  of noPictoSequence:
    if cr.isExtentedPic:
      cr.pictoSequence = inPictoExtend
    false
  of inPictoExtend:
    if cr.grapheme == GB_Extend:
      discard
    elif cr.grapheme == GB_ZWJ:
      cr.pictoSequence = seenPictoZWJ
    else:
      cr.pictoSequence = noPictoSequence
    false
  of seenPictoZWJ:
    if cr.isExtentedPic:
      cr.pictoSequence = inPictoExtend
      return true
    cr.pictoSequence = noPictoSequence
    false
  else:
    raiseAssert "exhaustive switch"

proc updateIndicConjunctBreakSequence(cr: var cursor): bool =
  let cb = cr.indicConjunctBreak
  case cr.indicConjunctBreakSequence
  of noIndicCBSequence:
    if cb == ICBConsonant:
      cr.indicConjunctBreakSequence = inIndicCBSequence
    false
  of inIndicCBSequence:
    if cb == ICBExtend:
      discard
    elif cb == ICBLinker:
      cr.indicConjunctBreakSequence = seenIndicCBSequence
    elif cb == ICBConsonant:
      discard
    else:
      cr.indicConjunctBreakSequence = noIndicCBSequence
    false
  of seenIndicCBSequence:
    if (cb and (ICBExtend or ICBLinker)) != 0:
      false
    elif cb == ICBConsonant:
      cr.indicConjunctBreakSequence = inIndicCBSequence
      true
    else:
      cr.indicConjunctBreakSequence = noIndicCBSequence
      false
  else:
    raiseAssert "exhaustive switch"

proc applyGraphemeBoundaryRules*(cr: var cursor): bool =
  let triggerGB9c = cr.updateIndicConjunctBreakSequence()
  let triggerGB11 = cr.updatePictoSequence()
  let triggerGB12_13 = cr.updateGraphemeRIOdd()

  let br0 = cr.prevGrapheme
  let br1 = cr.grapheme
  if cr.r == Rune(0x0A) and cr.prev == Rune(0x0D):
    false # Rule GB3
  elif (br0 and (GB_Control or GB_CR or GB_LF)) != 0 or
       (br1 and (GB_Control or GB_CR or GB_LF)) != 0:
    true # Rules GB4 && GB5
  elif br0 == GB_L and (br1 and (GB_L or GB_V or GB_LV or GB_LVT)) != 0:
    false # rule GB6
  elif (br0 and (GB_LV or GB_V)) != 0 and (br1 and (GB_V or GB_T)) != 0:
    false # rule GB7
  elif (br0 and (GB_LVT or GB_T)) != 0 and br1 == GB_T:
    false # rule GB8
  elif (br1 and (GB_Extend or GB_ZWJ)) != 0:
    false # Rule GB9
  elif br1 == GB_SpacingMark:
    false # Rule GB9a
  elif br0 == GB_Prepend:
    false # Rule GB9b
  elif triggerGB9c:
    false # Rule GB9c
  elif triggerGB11:
    false # Rule GB11
  elif triggerGB12_13:
    false # Rule GB12 && GB13
  else:
    true # Rule GB999

# ----------------------- Word boundaries (UAX #29) -----------------------

proc updateWordRIOdd(cr: var cursor): bool =
  if cr.word == WB_ExtendFormat:
    return false
  if cr.word == WB_Regional_Indicator:
    result = cr.isPrevWordRIOdd
    cr.isPrevWordRIOdd = not cr.isPrevWordRIOdd
  else:
    cr.isPrevWordRIOdd = false

proc applyWordBoundaryRules*(cr: var cursor, i: int): tuple[isWordBoundary, removePrevNoExtend: bool] =
  let triggerWB15_16 = cr.updateWordRIOdd()
  let prevPrev = cr.prevPrevWord
  let prev = cr.prevWord
  let current = cr.word
  let isAfterNoExtend = cr.prevWordNoExtend == i - 1

  if cr.prev == Rune(0x0D) and cr.r == Rune(0x0A): # Rule WB3
    result.isWordBoundary = false
  elif prev == WB_NewlineCRLF and isAfterNoExtend:
    result.isWordBoundary = true # Rule WB3a
  elif current == WB_NewlineCRLF:
    result.isWordBoundary = true # Rule WB3b
  elif cr.prev == Rune(0x200D) and cr.isExtentedPic:
    result.isWordBoundary = false # Rule WB3c
  elif prev == WB_WSegSpace and current == WB_WSegSpace and isAfterNoExtend:
    result.isWordBoundary = false # Rule WB3d
  elif current == WB_ExtendFormat:
    result.isWordBoundary = false # Rules WB4
  elif (prev and (WB_ALetter or WB_Hebrew_Letter or WB_Numeric)) != 0 and
       (current and (WB_ALetter or WB_Hebrew_Letter or WB_Numeric)) != 0:
    result.isWordBoundary = false # Rules WB5, WB8, WB9, WB10
  elif prev == WB_Katakana and current == WB_Katakana:
    result.isWordBoundary = false # Rule WB13
  elif (prev and (WB_ALetter or WB_Hebrew_Letter or WB_Numeric or WB_Katakana or WB_ExtendNumLet)) != 0 and
       current == WB_ExtendNumLet:
    result.isWordBoundary = false # Rule WB13a
  elif prev == WB_ExtendNumLet and
       (current and (WB_ALetter or WB_Hebrew_Letter or WB_Numeric or WB_Katakana)) != 0:
    result.isWordBoundary = false # Rule WB13b
  elif (prevPrev and (WB_ALetter or WB_Hebrew_Letter)) != 0 and
       (prev and (WB_MidLetter or WB_MidNumLet or WB_Single_Quote)) != 0 and
       (current and (WB_ALetter or WB_Hebrew_Letter)) != 0:
    result.removePrevNoExtend = true # Rule WB6
    result.isWordBoundary = false    # Rule WB7
  elif prev == WB_Hebrew_Letter and current == WB_Single_Quote:
    result.isWordBoundary = false # Rule WB7a
  elif prevPrev == WB_Hebrew_Letter and cr.prev == Rune(0x0022) and
       current == WB_Hebrew_Letter:
    result.removePrevNoExtend = true # Rule WB7b
    result.isWordBoundary = false    # Rule WB7c
  elif prevPrev == WB_Numeric and current == WB_Numeric and
       (prev and (WB_MidNum or WB_MidNumLet or WB_Single_Quote)) != 0:
    result.isWordBoundary = false    # Rule WB11
    result.removePrevNoExtend = true # Rule WB12
  elif triggerWB15_16:
    result.isWordBoundary = false # Rule WB15 and WB16
  else:
    result.isWordBoundary = true # Rule WB999

# ------------------------ Line boundaries (UAX #14) ----------------------

proc ruleLB1(cr: var cursor) =
  ## Apply rule LB1: resolve break classes AI, SG, XX, SA and CJ.
  case cr.line
  of LB_AI, LB_SG, LineBreak(0):
    cr.line = LB_AL
  of LB_SA:
    if cr.generalCategory == Mn or cr.generalCategory == Mc:
      cr.line = LB_CM
    else:
      cr.line = LB_AL
  of LB_CJ:
    cr.line = LB_NS
  else:
    discard

proc updateNumSequence(cr: var cursor): bool =
  if (cr.line and (LB_CM or LB_ZWJ)) != 0:
    return false
  case cr.numSequence
  of noNumSequence:
    if cr.line == LB_NU:
      cr.numSequence = inNumSequence
    false
  of inNumSequence:
    case cr.line
    of LB_NU, LB_SY, LB_IS:
      true
    of LB_CL, LB_CP:
      cr.numSequence = seenCloseNum
      true
    of LB_PO, LB_PR:
      cr.numSequence = noNumSequence
      true
    else:
      cr.numSequence = noNumSequence
      false
  of seenCloseNum:
    cr.numSequence = noNumSequence
    (cr.line and (LB_PO or LB_PR)) != 0
  else:
    raiseAssert "exhaustive switch"

proc applyLineBoundaryRules*(cr: var cursor): breakOpportunity =
  cr.ruleLB1()
  let triggerNumSequence = cr.updateNumSequence()

  let brm1 = cr.prevPrevLine
  let br0 = cr.prevLine
  let br1 = cr.line
  let br2 = cr.nextLine

  # LB4 and LB5
  if (br0 and (LB_BK or LB_LF or LB_NL)) != 0 or
     (br0 == LB_CR and cr.r != Rune(0x0A)):
    return breakMandatory

  # LB6, LB7
  if (br1 and (LB_BK or LB_CR or LB_LF or LB_NL or LB_SP or LB_ZW)) != 0:
    return breakProhibited

  # LB8, LB8a (raw classes: apply before LB9/LB10 remapping)
  if cr.beforeSpaceLineRaw == LB_ZW:
    return breakAllowed # rule LB8 : ZW SP* ÷
  elif cr.prevLineRaw == LB_ZWJ:
    return breakProhibited # rule LB8a : ZWJ ×

  # LB9 : "Do not break a combining character sequence"
  if (br1 and (LB_CM or LB_ZWJ)) != 0 and
     (br0 and (LB_BK or LB_CR or LB_LF or LB_NL or LB_SP or LB_ZW)) == 0:
    return breakProhibited

  # LB11
  if br0 == LB_WJ or br1 == LB_WJ:
    return breakProhibited

  # LB12 : GL ×; LB12a : [^SP BA HY HH] × GL
  if br0 == LB_GL or
     ((br0 and (LB_SP or LB_BA or LB_HY or LB_HH)) == 0 and br1 == LB_GL):
    return breakProhibited

  # LB13
  if (br1 and (LB_CL or LB_CP or LB_EX or LB_SY)) != 0:
    return breakProhibited

  let spaceM1 = cr.beforeSpacesLine

  # LB14 : OP SP* ×
  if spaceM1 == LB_OP:
    return breakProhibited

  # LB15a
  let spaceM2 = cr.prevBeforeSpacesLine
  if (cr.beforeSpacesIndex == 0 or
      (spaceM2 and (LB_BK or LB_CR or LB_LF or LB_NL or LB_OP or LB_QU or LB_GL or LB_SP or LB_ZW)) != 0) and
     (lookupGeneralCategory(int32(cr.beforeSpaces)) == Pi and spaceM1 == LB_QU):
    return breakProhibited

  # LB15b
  if cr.generalCategory == Pf and br1 == LB_QU and
     ((br2 and (LB_SP or LB_GL or LB_WJ or LB_CL or LB_QU or LB_CP or LB_EX or LB_IS or LB_SY or LB_BK or LB_CR or LB_LF or LB_NL or LB_ZW)) != 0 or
      cr.index == cr.len - 1):
    return breakProhibited
  elif br0 == LB_SP and br1 == LB_IS and br2 == LB_NU:
    return breakAllowed # LB15c : SP ÷ IS NU
  elif br1 == LB_IS:
    return breakProhibited # LB15d : × IS

  # LB16 : (CL | CP) SP* × NS
  if (spaceM1 and (LB_CL or LB_CP)) != 0 and br1 == LB_NS:
    return breakProhibited

  # LB17 : B2 SP* × B2
  if spaceM1 == LB_B2 and br1 == LB_B2:
    return breakProhibited

  # LB18 : SP ÷
  if br0 == LB_SP:
    return breakAllowed

  # LB19
  if (br1 == LB_QU and cr.generalCategory != Pi) or
     (br0 == LB_QU and cr.prevGeneralCategory != Pf):
    return breakProhibited

  # LB19a
  if (br1 == LB_QU and not isLargeEastAsian(int32(cr.prev))) or
     (br1 == LB_QU and (cr.index == cr.len - 1 or not isLargeEastAsian(int32(cr.next)))) or
     (br0 == LB_QU and not isLargeEastAsian(int32(cr.r))) or
     ((cr.isPreviousSot or not isLargeEastAsian(int32(cr.prevPrev))) and br0 == LB_QU):
    return breakProhibited

  # LB20 : ÷ CB, CB ÷
  if br0 == LB_CB or br1 == LB_CB:
    return breakAllowed

  # LB20a
  if (cr.isPreviousSot or
      (brm1 and (LB_BK or LB_CR or LB_LF or LB_NL or LB_SP or LB_ZW or LB_CB or LB_GL)) != 0) and
     (br0 and (LB_HY or LB_HH)) != 0 and (br1 and (LB_AL or LB_HL)) != 0:
    return breakProhibited

  # LB21
  if (br1 and (LB_BA or LB_HH or LB_HY or LB_NS)) != 0 or br0 == LB_BB:
    return breakProhibited
  # LB21a : HL (HY | HH) × [^HL]
  if cr.prevPrevLine == LB_HL and (br0 and (LB_HY or LB_HH)) != 0 and br1 != LB_HL:
    return breakProhibited
  # LB21b : SY × HL
  if br0 == LB_SY and br1 == LB_HL:
    return breakProhibited

  # LB22 : × IN
  if br1 == LB_IN:
    return breakProhibited

  # LB23 : (AL | HL) × NU ; NU × (AL | HL)
  if (br0 and (LB_AL or LB_HL)) != 0 and br1 == LB_NU:
    return breakProhibited
  if br0 == LB_NU and (br1 and (LB_AL or LB_HL)) != 0:
    return breakProhibited

  # LB23a
  if br0 == LB_PR and (br1 and (LB_ID or LB_EB or LB_EM)) != 0:
    return breakProhibited
  if (br0 and (LB_ID or LB_EB or LB_EM)) != 0 and br1 == LB_PO:
    return breakProhibited

  # LB24
  if (br0 and (LB_PR or LB_PO)) != 0 and (br1 and (LB_AL or LB_HL)) != 0:
    return breakProhibited
  if (br0 and (LB_AL or LB_HL)) != 0 and (br1 and (LB_PR or LB_PO)) != 0:
    return breakProhibited

  # LB25
  if (br0 and (LB_PR or LB_PO)) != 0 and
     (br1 == LB_NU or ((br1 and (LB_OP or LB_HY)) != 0 and cr.nextLine == LB_NU)):
    return breakProhibited
  if (br0 and (LB_OP or LB_HY or LB_IS)) != 0 and br1 == LB_NU:
    return breakProhibited
  if br0 == LB_NU and (br1 and (LB_NU or LB_SY or LB_IS)) != 0:
    return breakProhibited
  if triggerNumSequence:
    return breakProhibited

  # LB26
  if br0 == LB_JL and (br1 and (LB_JL or LB_JV or LB_H2 or LB_H3)) != 0:
    return breakProhibited
  if (br0 and (LB_JV or LB_H2)) != 0 and (br1 and (LB_JV or LB_JT)) != 0:
    return breakProhibited
  if (br0 and (LB_JT or LB_H3)) != 0 and br1 == LB_JT:
    return breakProhibited

  # LB27
  if (br0 and (LB_JL or LB_JV or LB_JT or LB_H2 or LB_H3)) != 0 and br1 == LB_PO:
    return breakProhibited
  if br0 == LB_PR and (br1 and (LB_JL or LB_JV or LB_JT or LB_H2 or LB_H3)) != 0:
    return breakProhibited

  # LB28a
  if (br0 == LB_AP and (cr.r == Rune(0x25CC) or (br1 and (LB_AK or LB_AS)) != 0)) or
     ((cr.isPrevDottedCircle or (br0 and (LB_AK or LB_AS)) != 0) and (br1 and (LB_VF or LB_VI)) != 0) or
     ((cr.isPrevPrevDottedCircle or (brm1 and (LB_AK or LB_AS)) != 0) and br0 == LB_VI and
      (br1 == LB_AK or cr.r == Rune(0x25CC))) or
     ((cr.isPrevDottedCircle or (br0 and (LB_AK or LB_AS)) != 0) and
      (cr.r == Rune(0x25CC) or (br1 and (LB_AK or LB_AS)) != 0) and br2 == LB_VF):
    return breakProhibited

  # LB28 : (AL | HL) × (AL | HL)
  if (br0 and (LB_AL or LB_HL)) != 0 and (br1 and (LB_AL or LB_HL)) != 0:
    return breakProhibited

  # LB29 : IS × (AL | HL)
  if br0 == LB_IS and (br1 and (LB_AL or LB_HL)) != 0:
    return breakProhibited

  # LB30a : (RI RI)* RI × RI
  if cr.isPrevLinebreakRIOdd and cr.line == LB_RI:
    return breakProhibited

  # LB30b
  if cr.prevLine == LB_EB and cr.line == LB_EM:
    return breakProhibited
  if cr.isPrevNonAssignedExtendedPic and cr.line == LB_EM:
    return breakProhibited

  # LB30
  if (cr.prevLine and (LB_AL or LB_HL or LB_NU)) != 0 and
     cr.line == LB_OP and not isLargeEastAsian(int32(cr.r)):
    return breakProhibited
  if cr.prevLine == LB_CP and not isLargeEastAsian(int32(cr.prev)) and
     (cr.line and (LB_AL or LB_HL or LB_NU)) != 0:
    return breakProhibited

  breakEmpty

# ------------------------------ Iteration -------------------------------

proc newCursor(text: openArray[Rune]): cursor =
  result.len = text.len
  result.prevWordNoExtend = -1
  if text.len != 0:
    result.nextLine = lookupLineBreak(int32(text[0]))

proc startIteration(cr: var cursor, text: openArray[Rune], i: int) =
  cr.index = i
  cr.prevPrev = cr.prev
  cr.prev = cr.r
  if i < text.len:
    cr.r = text[i]
  else:
    cr.r = paragraphSeparator
  if i == text.len:
    cr.next = Rune(0)
  elif i == text.len - 1:
    cr.next = paragraphSeparator
  else:
    cr.next = text[i + 1]

  cr.prevGeneralCategory = cr.generalCategory
  cr.generalCategory = lookupGeneralCategory(int32(cr.r))
  cr.isExtentedPic = isExtendedPictographic(int32(cr.r))
  cr.indicConjunctBreak = lookupIndicConjunctBreak(int32(cr.r))

  cr.line = cr.nextLine
  cr.nextLine = lookupLineBreak(int32(cr.next))

  cr.prevGrapheme = cr.grapheme
  cr.grapheme = lookupGraphemeBreak(int32(cr.r))

  if cr.word != WB_ExtendFormat:
    cr.prevPrevWord = cr.prevWord
    cr.prevWord = cr.word
    cr.prevWordNoExtend = i - 1
  cr.word = lookupWordBreak(int32(cr.r))

proc endIteration(cr: var cursor) =
  if (cr.line and (LB_CM or LB_ZWJ)) != 0:
    let isLB10 = (cr.prevLine and (LB_BK or LB_CR or LB_LF or LB_NL or LB_SP or LB_ZW)) != 0
    if cr.index == 0 or isLB10: # Rule LB10
      cr.prevLine = LB_AL
    # else rule LB9 : ignore the rune for prevLine and prevPrevLine
  else:
    cr.isPreviousSot = cr.index == 0
    if cr.line != LB_SP:
      cr.beforeSpaces = cr.r
      cr.prevBeforeSpaces = cr.prev
      cr.beforeSpacesIndex = cr.index
      cr.beforeSpacesLine = cr.line
      cr.prevBeforeSpacesLine = cr.prevLine
    cr.prevPrevLine = cr.prevLine
    cr.prevLine = cr.line
    cr.isPrevPrevDottedCircle = cr.isPrevDottedCircle
    cr.isPrevDottedCircle = cr.r == Rune(0x25CC)
    cr.isPrevNonAssignedExtendedPic = cr.isExtentedPic and cr.generalCategory == Unassigned

  cr.prevLineRaw = cr.line
  if cr.prevLine != LB_SP:
    cr.beforeSpaceLineRaw = cr.line

  if cr.line == LB_RI:
    cr.isPrevLinebreakRIOdd = not cr.isPrevLinebreakRIOdd
  elif (cr.line and (LB_CM or LB_ZWJ)) == 0:
    cr.isPrevLinebreakRIOdd = false

proc computeBreakAttributes(text: openArray[Rune], attributes: var seq[breakAttr]) =
  var cr = newCursor(text)
  for i in 0 .. text.len: # i == len(text) fills the last attribute
    cr.startIteration(text, i)
    var attr: breakAttr = 0
    if cr.applyGraphemeBoundaryRules():
      attr = attr or graphemeBoundary
    let (isWordBoundary, removePrevNoExtend) = cr.applyWordBoundaryRules(i)
    if isWordBoundary:
      attr = attr or wordBoundary
    if removePrevNoExtend:
      attributes[cr.prevWordNoExtend] = attributes[cr.prevWordNoExtend] and (not wordBoundary)
    case cr.applyLineBoundaryRules()
    of breakEmpty:
      attr = attr or lineBoundary # rule LB31
    of breakProhibited:
      attr = attr and (not lineBoundary)
    of breakAllowed:
      attr = attr or lineBoundary
    of breakMandatory:
      attr = attr or lineBoundary or mandatoryLineBoundary
    else:
      discard
    cr.endIteration()
    attributes[i] = attr
  attributes[0] = attributes[0] or graphemeBoundary or wordBoundary # GB1, WB1
  attributes[text.len] = attributes[text.len] or graphemeBoundary or wordBoundary # GB2, WB2
  attributes[0] = attributes[0] and (not lineBoundary) # LB2
  attributes[text.len] = attributes[text.len] or lineBoundary or mandatoryLineBoundary # LB3

# ------------------------------ Segmenter --------------------------------

type Segmenter* = object
  text: seq[Rune]
  attributes: seq[breakAttr]

proc initAttributes(seg: var Segmenter) =
  seg.attributes.setLen(seg.text.len + 1)
  for i in 0 .. seg.attributes.high:
    seg.attributes[i] = 0
  computeBreakAttributes(seg.text, seg.attributes)

proc init*(seg: var Segmenter, paragraph: openArray[Rune]) =
  seg.text.setLen(0)
  for r in paragraph:
    seg.text.add r
  seg.initAttributes()

proc initStr*(seg: var Segmenter, paragraph: string) =
  ## InitWithString: raises ValueError on invalid UTF-8.
  seg.text.setLen(0)
  var i = 0
  while i < paragraph.len:
    let r = runeAt(paragraph, i)
    let l = runeLenAt(paragraph, i)
    if int32(r) == int32(0xFFFD) and l != 3:
      raise newException(ValueError, "invalid UTF-8 sequence at index " & $i)
    seg.text.add r
    i += max(l, 1)
  seg.initAttributes()

type
  attributeIterator = object
    src: ptr Segmenter
    pos, lastBreak: int
    posInBytes, lastBreakInBytes: int
    flag: breakAttr

proc incrementPos(iter: var attributeIterator) =
  if iter.pos < iter.src.text.len:
    let l = runeByteLen(iter.src.text[iter.pos])
    if l > 0:
      iter.posInBytes += l
  inc iter.pos

proc next(iter: var attributeIterator): bool =
  iter.lastBreak = iter.pos
  iter.lastBreakInBytes = iter.posInBytes
  iter.incrementPos()
  while iter.pos <= iter.src.text.len:
    if (iter.src.attributes[iter.pos] and iter.flag) != 0:
      return true
    iter.incrementPos()
  false

type
  Line* = object
    text*: seq[Rune]
    offset*: int
    offsetInBytes*: int
    lengthInBytes*: int
    isMandatoryBreak*: bool

  LineIterator* = object
    it: attributeIterator

proc next*(li: var LineIterator): bool = li.it.next()

proc line*(li: LineIterator): Line =
  Line(
    offset: li.it.lastBreak,
    offsetInBytes: li.it.lastBreakInBytes,
    lengthInBytes: li.it.posInBytes - li.it.lastBreakInBytes,
    text: li.it.src.text[li.it.lastBreak ..< li.it.pos],
    isMandatoryBreak: (li.it.src.attributes[li.it.pos] and mandatoryLineBoundary) != 0)

proc lineIterator*(sg: var Segmenter): LineIterator =
  LineIterator(it: attributeIterator(src: addr sg, flag: lineBoundary))

type
  Grapheme* = object
    text*: seq[Rune]
    offset*: int
    offsetInBytes*: int
    lengthInBytes*: int

  GraphemeIterator* = object
    it: attributeIterator

proc next*(gr: var GraphemeIterator): bool = gr.it.next()

proc grapheme*(gr: GraphemeIterator): Grapheme =
  Grapheme(
    offset: gr.it.lastBreak,
    offsetInBytes: gr.it.lastBreakInBytes,
    lengthInBytes: gr.it.posInBytes - gr.it.lastBreakInBytes,
    text: gr.it.src.text[gr.it.lastBreak ..< gr.it.pos])

proc graphemeIterator*(sg: var Segmenter): GraphemeIterator =
  GraphemeIterator(it: attributeIterator(src: addr sg, flag: graphemeBoundary))

type
  Word* = object
    text*: seq[Rune]
    offset*: int
    offsetInBytes*: int
    lengthInBytes*: int

  WordIterator* = object
    it: attributeIterator
    inWord: bool

proc next*(gr: var WordIterator): bool =
  if not gr.it.next():
    return false
  if gr.inWord:
    gr.inWord = false
    return true
  if gr.it.pos < gr.it.src.text.len:
    gr.inWord = isWord(int32(gr.it.src.text[gr.it.pos]))
  gr.next()

proc word*(gr: WordIterator): Word =
  Word(
    offset: gr.it.lastBreak,
    offsetInBytes: gr.it.lastBreakInBytes,
    lengthInBytes: gr.it.posInBytes - gr.it.lastBreakInBytes,
    text: gr.it.src.text[gr.it.lastBreak ..< gr.it.pos])

proc wordIterator*(sg: var Segmenter): WordIterator =
  var inWord = false
  if sg.text.len != 0:
    inWord = isWord(int32(sg.text[0]))
  WordIterator(it: attributeIterator(src: addr sg, flag: wordBoundary),
               inWord: inWord)
