import mynim/ui as ui

doAssert ui.rubberband(50, 0, 100, 200) == 50
let over = ui.rubberband(150, 0, 100, 200)
let under = ui.rubberband(-50, 0, 100, 200)
doAssert over > 100 and over < 150
doAssert over - 100 == -under
doAssert ui.rubberband(1e6'f32, 0, 100, 200) < 300
doAssert ui.rubberband(-1e6'f32, 0, 100, 200) > -200
doAssert ui.rubberband(-50, 0, 100, 0) == 0
doAssert ui.rubberband(150, 0, 100, -1) == 100

let projected = ui.project(0, 1000)
doAssert projected >= 498 and projected <= 500
doAssert ui.project(25, -1000) < 25
