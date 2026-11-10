// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Real terminal captures with editor-side readiness and ownership checks.
/// Screenshots still require human visual inspection; API assertions alone are insufficient.
extension Smoke {
  static func auditUI() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let backend = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let nvim = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let selected = ProcessInfo.processInfo.environment["TATARA_UI_AUDIT_PROFILES"]?.components(separatedBy: ",")
    for (name, columns, rows, user) in [
      ("wide", 176, 48, false),
      ("medium", 120, 40, false),
      ("threshold", 100, 32, false),
      ("stacked", 80, 32, false),
      ("compact", 64, 24, false),
      ("short", 160, 24, false),
      ("configured-wide", 176, 48, true),
      ("configured-stacked", 80, 32, true),
    ] {
      if let selected, !selected.contains(name) {
        continue
      }
      if user, ProcessInfo.processInfo.environment["TATARA_UI_AUDIT_USER_CONFIG"] != "1" {
        continue
      }
      let audit = try EditorAudit(
        root: root,
        backend: backend,
        nvim: nvim,
        name: name,
        columns: columns,
        rows: rows,
        user: user,
      )
      defer { audit.terminal.close() }
      try audit.wait(
        "ready",
        "local s=A.session(); return s and s.mode=='combined' and require('tatara.diff').document(vim.api.nvim_win_get_buf(s.right_win)) and not next(s.rpc.pending)",
      )
      try audit.capture("workspace")
      try audit.lua("local s=A.session(); vim.api.nvim_set_current_win(s.right_win)")
      try audit.lua("""
        A.scroll_calls=0; A.scroll_events=0
        local d=require('tatara.diff'); local sync=d.sync
        d.sync=function(...) A.scroll_calls=A.scroll_calls+1; return sync(...) end
        vim.api.nvim_create_autocmd('WinScrolled',{callback=function() A.scroll_events=A.scroll_events+1 end})
        """)
      try audit.capture("focused-diff")
      if user {
        audit.terminal.key("gFG")
        try audit.wait(
          "cursor-only file preview",
          "local s=A.session(); local d=require('tatara.diff').document(vim.api.nvim_win_get_buf(s.right_win)); return vim.api.nvim_get_current_win()==s.files_win and d and #d.results==1 and d.results[1].path=='Sources/Selection.swift'",
        )
        try audit.capture("focused-file-preview")
        audit.terminal.key("k")
        try audit.wait(
          "previous file preview",
          "local s=A.session(); local d=require('tatara.diff').document(vim.api.nvim_win_get_buf(s.right_win)); return d and #d.results==1 and d.results[1].path=='Sources/ReviewQueue.swift'",
        )
        audit.terminal.key("gg")
        try audit.wait("root preview restored", "return A.session().mode=='combined' and #A.session().projection_results==2")
        try audit.lua("vim.api.nvim_set_current_win(A.session().right_win)")
      }
      if columns >= 160 {
        // Make the tiny fixture overflow with the user's scrolling margins.
        // Preserve those settings rather than overriding them for the test.
        if rows > 24 {
          audit.terminal.resize(columns: columns, rows: 24)
          try audit.wait("scroll viewport", "return vim.o.lines==24")
        }
        audit.terminal.key("6\u{5}")
        try audit.wait("native diff scrolling", "return vim.fn.line('w0')>1")
        try audit.capture("scrolled-diff")
        audit.terminal.key("ggzt")
        try audit.wait("diff header restored", "return vim.fn.line('w0')==1")
        if rows > 24 {
          audit.terminal.resize(columns: columns, rows: rows)
          try audit.wait("full viewport restored", "return vim.o.lines==\(rows)")
        }
      }
      // Long paths and literal statusline syntax must not consume the title or revision.
      if name == "wide" {
        try audit
          .lua(
            "local s=A.session(); A.repository=s.repository; s.repository='github.com/example/프로젝트-非常に長い-repository-%name'; require('tatara.chrome').refresh(s,true)"
          )
        try audit.capture("unicode-title")
        try audit.lua("A.session().repository=A.repository")
        try audit.lua("""
          local s=A.session(); local api=vim.api; local doc=require('tatara.diff').document(api.nvim_win_get_buf(s.right_win))
          for row,p in pairs(doc.locations) do if p.path=='Sources/ReviewQueue.swift' and p.side=='RIGHT' and p.line==5 then
            api.nvim_set_current_win(s.right_win); api.nvim_win_set_cursor(s.right_win,{row,p.offset}); break end end
          """)
        audit.terminal.key("c")
        try audit.wait("projected composer", "return vim.bo.buftype=='acwrite'")
        audit.terminal.key("Projected draft preserved")
        try audit.capture("projected-comment")
        audit.terminal.resize(columns: 80, rows: 32)
        try audit.wait(
          "projected composer reflow",
          "return A.session().narrow and vim.bo.buftype=='acwrite' and vim.api.nvim_win_get_width(0)<=80",
        )
        try audit.capture("projected-comment-stacked")
        audit.terminal.resize(columns: 176, rows: 48)
        try audit.wait(
          "projected composer restored",
          "return not A.session().narrow and vim.bo.buftype=='acwrite' and vim.api.nvim_win_get_width(0)>80",
        )
        try audit.capture("projected-comment-wide")
        audit.terminal.key("\u{1b}\u{1b}")
        try audit.wait(
          "projected source restored",
          "return vim.bo.filetype=='tatara-diff' and require('tatara').get_context().line==5",
        )
        audit.terminal.key("c")
        try audit.wait("projected draft retained", "return vim.bo.buftype=='acwrite'")
        try audit
          .lua(
            "assert(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\\n')=='Projected draft preserved'); vim.api.nvim_buf_set_lines(0,0,-1,false,{''})"
          )
        audit.terminal.key("\u{1b}\u{1b}")
        try audit.wait("projected editor closed", "return vim.bo.filetype=='tatara-diff'")
      }
      try audit.lua("require('tatara').open_file('Sources/ReviewQueue.swift', {side='RIGHT',line=5,native=true})")
      try audit.wait(
        "native source",
        "return vim.bo.buftype=='' and A.session().current_buffers and not next(A.session().rpc.pending)",
      )
      try audit.capture("native-source")
      try audit.lua("require('tatara').mark_hunk_reviewed()")
      try audit.wait("saved hunk progress", "return next(A.session().reviewed_hunks) and not next(A.session().rpc.pending)")
      try audit.capture("review-progress")
      try audit.lua("require('tatara').suggest({start_line=5,end_line=6})")
      try audit.wait("suggestion editor", "return vim.bo.buftype=='acwrite'")
      try audit.capture("suggestion")
      audit.terminal.key("\u{1b}\u{1b}")
      try audit.wait("suggestion closed", "return vim.bo.buftype=='' and require('tatara').get_context().line==5")
      try audit.lua("require('tatara').file_comment('Sources/ReviewQueue.swift')")
      try audit.wait("file comment editor", "return vim.bo.buftype=='acwrite'")
      try audit.capture("file-comment")
      audit.terminal.key("\u{1b}\u{1b}")
      try audit.wait("file comment closed", "return vim.bo.buftype=='' and require('tatara').get_context().line==5")
      audit.terminal.key("c")
      try audit.wait("inline editor", "return vim.bo.buftype=='acwrite' and vim.api.nvim_win_get_config(0).relative~=''")
      try audit.capture("comment")
      if name == "wide" {
        audit.terminal.resize(columns: 80, rows: 32)
        try audit.wait(
          "active composer reflow",
          "return vim.o.columns==80 and vim.api.nvim_win_get_width(0)<=80 and A.session().narrow",
        )
        try audit.capture("comment-resized-stacked")
        audit.terminal.resize(columns: 176, rows: 48)
        try audit.wait(
          "active composer wide",
          "return vim.o.columns==176 and vim.api.nvim_win_get_width(0)>80 and not A.session().narrow",
        )
        try audit.capture("comment-resized-wide")
      }
      audit.terminal.key("A comment from the visual audit.\u{1b}:write\r")
      try audit.wait("saved draft", "return #A.session().draft==1 and vim.bo.buftype~='acwrite'")
      audit.terminal.key("R")
      try audit.wait(
        "review editor",
        "local s=A.session(); return s.form and s.form.kind=='review' and s.form.windows.drafts and vim.api.nvim_win_is_valid(s.form.windows.drafts)",
      )
      try audit.capture("review")
      audit.terminal.key("A review from the visual audit.\u{1b}g2:write\r")
      try audit.wait("review preview", "return A.session().mode=='preview' and not next(A.session().rpc.pending)")
      try audit.capture("preview")
      audit.terminal.key("\u{1b}")
      try audit.wait("review restored", "return A.session().mode=='review'")
      audit.terminal.key("\u{1b}")
      try audit.wait("source restored", "return not A.session().form and vim.bo.buftype==''")
      try audit.lua("require('tatara').saved_reviews()")
      try audit.wait("saved review workspace", "return A.session().mode=='saved_reviews' and not next(A.session().rpc.pending)")
      try audit.capture("saved-reviews")
      try audit.lua("require('tatara').open_file('Sources/ReviewQueue.swift',{side='RIGHT',line=5,native=true})")
      try audit.wait("source from saved reviews", "return vim.bo.buftype=='' and not next(A.session().rpc.pending)")
      try audit.lua("require('tatara').filter_files()")
      try audit.wait("file filters", "return vim.bo.buftype=='acwrite'")
      try audit.capture("file-filters")
      audit.terminal.key("\u{1b}\u{1b}")
      try audit.wait("file filters closed", "return vim.bo.buftype==''")
      try audit.lua("require('tatara').filters()")
      try audit.wait("filters", "local f=A.session().form; return f and f.kind=='filters' and f.windows.labels")
      try audit.capture("filters")
      audit.terminal.key("\u{17}j")
      try audit.capture("focused-presets")
      // Leave through the actual query buffer, preserving native C-w behavior.
      try audit.lua("vim.api.nvim_set_current_win(A.session().right_win)")
      audit.terminal.key("\u{1b}")
      try audit.wait("filters closed", "return not A.session().form and vim.bo.buftype=='' and not next(A.session().rpc.pending)")
      try audit.lua("require('tatara').list()")
      try audit.wait(
        "list preview",
        "local s=A.session(); return s.mode=='list' and s.preview_selected and not next(s.rpc.pending)",
      )
      try audit.capture("selection")
      audit.terminal.key("\u{1b}")
      try audit.wait(
        "list closed",
        "return A.session().mode=='diff' and vim.bo.buftype=='' and not next(A.session().rpc.pending)",
      )
      if user {
        for (name, invocation, query) in [("file-picker", "find_files", "selection"), ("content-picker", "grep", "guard")] {
          try audit.lua("vim.schedule(function() require('tatara').\(invocation)() end)")
          try audit.wait("configured picker", "return _G.MiniPick and MiniPick.get_picker_opts()")
          audit.terminal.key(query)
          try audit.wait(
            "live picker results",
            "local p=MiniPick.get_picker_state(); local m=MiniPick.get_picker_matches(); return p and not p.is_busy and m and m.current",
          )
          try audit.capture(name)
          audit.terminal.key("\u{1b}")
          try audit.wait("picker closed", "return not MiniPick.get_picker_opts()")
        }
      }
      if name == "wide" {
        for border in ["none", "single", "double", "rounded"] {
          try audit.lua("vim.o.winborder='\(border)'; require('tatara').comment()")
          try audit.wait("border preference", "return vim.bo.buftype=='acwrite'")
          try audit.capture("comment-\(border)")
          audit.terminal.key("\u{1b}\u{1b}")
          try audit.wait("comment closed", "return vim.bo.buftype~='acwrite'")
        }
        for flavor in ["latte", "inherit", "mocha"] {
          try audit
            .lua(
              "vim.o.background='\(flavor == "latte" ? "light" : "dark")'; require('tatara.config').get().theme='\(flavor)'; require('tatara.theme').apply(true); require('tatara.chrome').refresh(A.session(),true)"
            )
          try audit.capture("theme-\(flavor)")
        }
        audit.terminal.resize(columns: 80, rows: 32)
        try audit.wait("live narrow reflow", "return vim.o.columns==80 and A.session().narrow")
        try audit.capture("resized-stacked")
        audit.terminal.resize(columns: 176, rows: 48)
        try audit.wait("live wide reflow", "return vim.o.columns==176 and not A.session().narrow")
        try audit.capture("resized-wide")
      }
      try audit
        .lua(
          "require('tatara.config').notify('Check your configuration.\\nA detailed notification must fit the review workspace.',vim.log.levels.ERROR)"
        )
      try audit.capture("notification")
      try audit.lua("require('tatara').close()")
      try audit.capture("restored-editor", chrome: false)
      audit.terminal.key(":qa!\r")
      try audit.terminal.finish()
      print("UI audit passed: \(name), \(columns)x\(rows), \(user ? "user configuration" : "clean configuration").")
    }
  }
}

// MARK: - EditorAudit

private final class EditorAudit {

  // MARK: Lifecycle

  init(root: URL, backend: URL, nvim: URL, name: String, columns: Int, rows: Int, user: Bool) throws {
    self.nvim = nvim
    socket = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-ui-\(UUID()).sock")
    let output = ProcessInfo.processInfo.environment["TATARA_UI_AUDIT_OUTPUT"]
      .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".artifacts/neovim-ui-audit")
    artifacts = output.appendingPathComponent(name)
    var arguments = user ? ["-n"] : ["--clean", "-u", root.appendingPathComponent("tests/nvim/pty_init.lua").path]
    arguments += ["-i", "NONE", "--listen", socket.path, "--cmd", "lua vim.opt.rtp:prepend(vim.env.TATARA_SOURCE_ROOT)"]
    if user {
      arguments += [
        "-c",
        "lua vim.opt.rtp:prepend(vim.env.TATARA_SOURCE_ROOT); vim.api.nvim_create_autocmd('User',{pattern='TataraReady',once=true,callback=function() if package.loaded.persisted then require('persisted').stop() end end}); require('tatara').setup({backend=vim.env.TATARA_TEST_BACKEND,reduce_motion=true}); require('tatara').start({demo=true})",
      ]
    }
    terminal = try PTY(
      binary: nvim,
      arguments: arguments,
      columns: columns,
      rows: rows,
      environment: ["TATARA_TEST_BACKEND": backend.path, "TATARA_SOURCE_ROOT": root.path],
      cwd: root,
      artifacts: artifacts,
    )
    try terminal.wait("Keep review navigation within bounds")
    try lua(
      "_G.TataraUIAudit={}; function TataraUIAudit.session() return require('tatara.chrome').sessions[vim.api.nvim_get_current_tabpage()] end"
    )
  }

  // MARK: Internal

  let terminal: PTY

  @discardableResult
  func lua(_ body: String) throws -> Any {
    let source = "(function() local A=_G.TataraUIAudit; local result=(function() \(body) end)(); if result==nil then return true end; return result end)()"
    let expression = "json_encode(luaeval('\(source.replacing("'", with: "''"))'))"
    let process = Process()
    let output = Pipe()
    process.executableURL = nvim
    process.arguments = ["--server", socket.path, "--remote-expr", expression]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw SmokeError("Editor audit RPC failed: \(String(decoding: data, as: UTF8.self))")
    }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  func wait(_ label: String, _ condition: String) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while ProcessInfo.processInfo.systemUptime < deadline {
      if try lua("return not not (function() \(condition) end)()") as? Bool == true {
        terminal.read(for: 0.03)
        return
      }
      terminal.read(for: 0.02)
    }
    try terminal.snapshot("failure")
    let diagnostics = try lua("""
      local modules={}; for name,m in pairs(package.loaded) do
        if name:match('^tatara') and type(m)=='table' then
          for _,f in pairs(m) do if type(f)=='function' then modules[name]=debug.getinfo(f,'S').source; break end end
        end
      end
      return {messages=vim.fn.execute('messages'),modules=modules,context=require('tatara').get_context(),runtime=vim.o.runtimepath}
      """)
    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("failure.json"))
    throw SmokeError("UI audit timed out: \(label), \(artifacts.path)")
  }

  func capture(_ name: String, chrome: Bool = true) throws {
    terminal.read(for: 0.03)
    try terminal.screenshot(name)
    let windows = try lua("""
      local api=vim.api; local result={}
      vim.cmd('redraw!')
      local s=A.session()
      if s and s.inline_editor and api.nvim_win_is_valid(s.inline_editor.win) then
        assert(api.nvim_get_current_win()==s.inline_editor.win, 'Resize moved focus out of the composer')
        assert(vim.fn.mode():sub(1,1)=='i', 'Resize left the native Insert mode')
        assert(vim.wo.statusline:find('Add comment to review',1,true), 'Composer statusline shows background actions')
        local cfg=api.nvim_win_get_config(s.inline_editor.win)
        local source=vim.w.tatara_anchor
        assert(source and vim.api.nvim_win_is_valid(source.win), 'Comment popup lost its source identity')
        local anchor=vim.fn.screenpos(source.win,source.row,1)
        if anchor and anchor.row>0 then
          local position=api.nvim_win_get_position(s.inline_editor.win)
          local h=api.nvim_win_text_height(source.win,{start_row=source.row-1,end_row=source.row-1,start_vcol=0})
          local bottom=position[1]+api.nvim_win_get_height(s.inline_editor.win)+(cfg.border and #cfg.border>0 and 2 or 0)
          assert(bottom<=anchor.row-1 or position[1]>=anchor.row-1+h.all-h.fill,
            'Comment popup covers its source anchor '..vim.inspect({float=cfg,position=position,anchor=anchor,
              lineHeight=h,parent=api.nvim_win_get_position(source.win),parentHeight=api.nvim_win_get_height(source.win)}))
        end
      end
      if s and s.mode=='diff' and not require('tatara.config').get().diff.context_folds then
        for _,w in pairs({s.left_win,s.right_win}) do
          if vim.api.nvim_win_is_valid(w) then
            assert(vim.wo[w].foldexpr==\"v:lua.require'tatara.diff'.fold(v:lnum)\", 'Comment FileType changed source folding')
            for row=1,vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w)) do
              assert(vim.api.nvim_win_call(w,function() return vim.fn.foldclosed(row) end)==-1,'Comment interaction hid source rows')
            end
          end
        end
      end
      if s and not (s.inline_editor and api.nvim_win_is_valid(s.inline_editor.win))
        and (s.mode=='combined' or s.mode=='diff') and s.left_win and api.nvim_win_is_valid(s.left_win)
        and api.nvim_win_get_position(s.left_win)[1]==api.nvim_win_get_position(s.right_win)[1] then
        local D=require('tatara.diff'); local L=D.document(api.nvim_win_get_buf(s.left_win)); local R=D.document(api.nvim_win_get_buf(s.right_win))
        local indices={LEFT={},RIGHT={}}
        for side,doc in pairs({LEFT=L,RIGHT=R}) do
          for row,p in pairs(doc.locations) do indices[side][p.path..':'..p.line]=row end
        end
        for _,r in ipairs(s.mode=='combined' and s.projection_results or {s.current_result}) do
          for _,pair in ipairs(r.diff.alignment) do
            local l=L and indices.LEFT[r.path..':'..tostring(pair[1])] or pair[1]
            local q=R and indices.RIGHT[r.path..':'..tostring(pair[2])] or pair[2]
            if type(l)=='number' and type(q)=='number'
              and api.nvim_win_call(s.left_win,function() return vim.fn.foldclosed(l) end)==-1
              and api.nvim_win_call(s.right_win,function() return vim.fn.foldclosed(q) end)==-1 then
              local a,b=vim.fn.screenpos(s.left_win,l,1),vim.fn.screenpos(s.right_win,q,1)
              if a.row>0 and b.row>0 then
                if a.row~=b.row then
                  local ns=api.nvim_get_namespaces()['tatara.structural-alignment']
                  error('Difftastic screen rows disagree at '..r.path..':'..tostring(pair[1])..'/'..tostring(pair[2])..' = '..a.row..'/'..b.row..' '..vim.inspect({
                    calls=A.scroll_calls,events=A.scroll_events,ignore=vim.o.eventignore,current=api.nvim_get_current_win(),
                    session={applying=s.applying_file,paired=s.projection_paired,tab=s.tab,currentTab=api.nvim_get_current_tabpage()},
                    ignoreLeft=vim.wo[s.left_win].eventignorewin,ignoreRight=vim.wo[s.right_win].eventignorewin,
                    bindLeft=vim.wo[s.left_win].scrollbind,bindRight=vim.wo[s.right_win].scrollbind,
                    handlers=api.nvim_get_autocmds({group=s.group,event='WinScrolled'}),
                    left=api.nvim_buf_get_extmarks(api.nvim_win_get_buf(s.left_win),ns,0,-1,{details=true}),
                    right=api.nvim_buf_get_extmarks(api.nvim_win_get_buf(s.right_win),ns,0,-1,{details=true}),
                    viewLeft=api.nvim_win_call(s.left_win,vim.fn.winsaveview),viewRight=api.nvim_win_call(s.right_win,vim.fn.winsaveview),
                    actualWidthLeft=vim.fn.getwininfo(s.left_win),actualWidthRight=vim.fn.getwininfo(s.right_win)}))
                end
              end
            end
          end
        end
      end
      for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do
        local cfg=api.nvim_win_get_config(win)
        local bar=vim.wo[win].winbar
        if \(chrome) and cfg.relative=='' then
          for _,corner in ipairs({'╭','╮','╰','╯'}) do
            assert(not bar:find(corner,1,true), 'Split has a simulated rounded border')
          end
          if not vim.wo[win].number then
            assert(not vim.wo[win].statuscolumn:find('│',1,true), 'Source gutter draws a second border')
          end
          assert(vim.wo[win].statusline==vim.go.statusline,'Window-local statusline hides actions')
        end
        result[#result+1]={win=win,config=cfg,position=api.nvim_win_get_position(win),
          width=api.nvim_win_get_width(win),height=api.nvim_win_get_height(win),
          buffer=api.nvim_buf_get_name(api.nvim_win_get_buf(win)),winbar=bar,
          title=api.nvim_eval_statusline(bar,{winid=win,use_winbar=true,maxwidth=api.nvim_win_get_width(win)}),
          statusline=vim.wo[win].statusline,winhighlight=vim.wo[win].winhighlight}
      end
      vim.cmd('redraw!'); return result
      """)
    try JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent(name + ".json"))
    terminal.read(for: 0.08)
    try terminal.screenshot(name)
  }

  // MARK: Private

  private let nvim: URL
  private let socket: URL
  private let artifacts: URL

}
