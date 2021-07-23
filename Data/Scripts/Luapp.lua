--------------------------------------------------------------------------
--  An attempt to write robust pretty-printer for lua structures.
--
--  @author: andrew_zhilin@yahoo.com
--  @Copyright (C) 2008-2021 by zOOn
--  https://github.com/zoon/luapp
--------------------------------------------------------------------------
-- compiled from hlua, unreadable ^_^
local RESPECT_TOSTRING_MT = true -- hacky for lua 5.2+
local format, gsub = string.format, string.gsub
local function errfmt(argn,varargs,...)
  local MAX_TAB = 5
  local args = {...}
  local argslen = select("#", ...)
  argslen = (argn and argn>argslen) and argn or argslen
  local function get_type(_u0)
    if type(_u0) == 'table' or type(_u0) == 'userdata' then
      local mt = getmetatable(_u0)
      if mt and mt.type and type(mt.type) == 'function' then
        return _u0:type()
      else return type(_u0)
      end
    else return type(_u0)
    end
  end
  local function atom(x)
    if type(x) == 'string' then return format('%q:%s',x,'string')
    else return format('%s:%s',tostring(x),get_type(x))
    end
  end
  local function key(x)
    if type(x) == 'number' then return ""
    else return '['..atom(x) ..']='
    end
  end
  local function one_arg(i,x)
    local what = 'arg#'..i ..":\t"
    if type(x) == 'table' then
      local n = 0
      what = what ..'{'
      for k,v in pairs(x) do
        what = what ..(key(k) ..atom(v) ..',')
        n = n+1
        if n == MAX_TAB then what = what .." ..." break end
      end
      what = what ..'}:'..get_type(x)
    else what = what ..atom(x)
    end
    what = what ..'\n'
    return what
  end
  local res = 'pattern-match error:\n'
  if varargs ~= false then
    res = res ..'varargs possible after arg#'..argn ..'.\n'
  end
  if argn ~= 0 then
    res = res ..argn ..' args were expected, in fact we got:\n'
  end
  for i=1,argslen do res = res ..one_arg(i,args[i]) end
  if debug and type(debug) == 'table' then
    return res ..(gsub(debug.traceback"",'\t','')) ..'\n'
  else return res
  end
end

-- zpp
local error = error
local tostring = tostring
local rep = string.rep
local min,max = math.min,math.max
local type = type
local spaces = function(_u53) return rep(" ",_u53) end
local compose = function(f,g)
  return function(x) return f(g(x)) end
end
local identity = function(...) return ... end
local function i2list(_u54)
  local res = '<#null>'
  for i=#_u54,1,-1 do res = {_u54[i];res}; end
  return res
end
local function foldl(_u55,_u56,_u57)
  if '<#null>' == _u57 then return _u56
  else
    if type(_u57) == 'table' and #_u57 == 2 then
      return foldl(_u55,_u55(_u56,_u57[1]),_u57[2])
    else error(errfmt(3,false,_u55,_u56,_u57))
    end
  end
end
local Doc_mt = {}
Doc_mt.__index = Doc_mt
local function Doc(_u58)
  if type(_u58) == 'table' and (#_u58 == 2 and
     _u58.tag ~= nil and (_u58.tag == 'Cat' or
     _u58.tag == 'Nest') or #_u58 == 1 and _u58.tag ~= nil and
     (_u58.tag == 'Text' or _u58.tag == 'Break' or
     _u58.tag == 'Group' or _u58.tag == 'Column' or
     _u58.tag == 'Nesting') or #_u58 == 0 and _u58.tag ~= nil and
     _u58.tag == 'Empty')
  then
    return setmetatable(_u58,Doc_mt)
  else error(errfmt(1,false,_u58))
  end
end
local Empty = Doc{tag='Empty'}
local isDoc = function(_u59)
  if type(_u59) == 'table' then
    return getmetatable(_u59) == Doc_mt
  else return false
  end
end
local empty = Empty
local text = function(_u60)
  return Doc{tag='Text';tostring(_u60)}
end
local nest = function(_u61,_u62)
  if type(_u61) == 'number' and isDoc(_u62) then
    return Doc{tag='Nest';_u61;_u62}
  else error(errfmt(2,false,_u61,_u62))
  end
end
local group = function(_u63)
  if isDoc(_u63) then return Doc{tag='Group';_u63}
  else error(errfmt(1,false,_u63))
  end
end
local column = function(_u64)
  if type(_u64) == 'function' then return Doc{tag='Column';_u64}
  else error(errfmt(1,false,_u64))
  end
end
local nesting = function(_u65)
  if type(_u65) == 'function' then
    return Doc{tag='Nesting';_u65}
  else error(errfmt(1,false,_u65))
  end
end
local line = Doc{tag='Break';" "}
local linebreak = Doc{tag='Break';""}
local space = text" "
local softline = group(line)
local softbreak = group(linebreak)
local function cat(_u66,_u67)
  if _u66 == Empty then
    if isDoc(_u67) then return _u67
    else
      if isDoc(_u66) and _u67 == Empty then return _u66
      else error(errfmt(2,false,_u66,_u67))
      end
    end
  else
    if isDoc(_u66) then
      if _u67 == Empty then return _u66
      else
        if isDoc(_u67) then return Doc{tag='Cat';_u66;_u67}
        else error(errfmt(2,false,_u66,_u67))
        end
      end
    else error(errfmt(2,false,_u66,_u67))
    end
  end
end
local function catspace(_u68,_u69)
  return cat(_u68,(cat(space,_u69)))
end
local function above(_u70,_u71)
  return cat(_u70,(cat(linebreak,_u71)))
end
local function abovespace(_u72,_u73)
  return cat(_u72,(cat(line,_u73)))
end
local function abovesoft(_u74,_u75)
  return cat(_u74,(cat(softbreak,_u75)))
end
local function abovesoftspace(_u76,_u77)
  return cat(_u76,(cat(softline,_u77)))
end
local function foldDoc(_u79,_u80)
  if type(_u79) == 'function' and isDoc(_u80) then
    return function(_u78)
      if type(_u78) == 'table' and #_u78 == 2 or '<#null>' == _u78
      then
        return foldl(_u79,_u80,_u78)
      else error(errfmt(1,false,_u78))
      end
    end
  else error(errfmt(2,false,_u79,_u80))
  end
end
local function separateWith(_u84,_u85)
  if isDoc(_u84) and type(_u85) == 'function' then
    return function(_u83)
      if '<#null>' == _u83 then return empty
      else
        if type(_u83) == 'table' and #_u83 == 2 then
          if '<#null>' == _u83[2] then return _u85(_u83[1])
          else
            return foldDoc(function(_u81,_u82)
                            return cat(_u81,(cat(_u85(_u82),_u84)))
                          end
                          ,_u85(_u83[1]))(_u83[2])
          end
        else error(errfmt(1,false,_u83))
        end
      end
    end
  else error(errfmt(2,false,_u84,_u85))
  end
end
local function ifoldDoc(_u87)
  if type(_u87) == 'function' then
    return function(_u86)
      if type(_u86) == 'table' then
        if #_u86 == 0 then return empty
        else
          if #_u86 == 1 then return _u86[1]
          else
            if #_u86 >= 1 then
              local seed = _u86[1]
              for i=2,#_u86 do seed = _u87(seed,_u86[i]); end
              return seed
            else error(errfmt(1,false,_u86))
            end
          end
        end
      else error(errfmt(1,false,_u86))
      end
    end
  else error(errfmt(1,false,_u87))
  end
end
local function iseparateWith(_u89,_u90)
  if isDoc(_u89) and type(_u90) == 'function' then
    return function(_u88)
      if type(_u88) == 'table' then
        if #_u88 == 0 then return empty
        else
          if #_u88 == 1 then return _u90(_u88[1])
          else
            local seed = empty
            for i=1,(#_u88-1) do
              seed = cat(seed,(cat(_u90(_u88[i]),_u89)))
            end
            return cat(seed,_u90(_u88[#_u88]))
          end
        end
      else error(errfmt(1,false,_u88))
      end
    end
  else error(errfmt(2,false,_u89,_u90))
  end
end
local align = function(doc)
  return column(function(k)
    return nesting(function(i) return nest(k-i,doc) end)
  end)
end
local hang = function(i,doc) return align(nest(i,doc)) end
local indent = function(i,doc)
  return hang(i,cat(text(spaces(i)),doc))
end
local width = function(_u91,_u92)
  if isDoc(_u91) and type(_u92) == 'function' then
    return column(function(k1)
      return cat(_u91,column(function(k2) return _u92(k2-k1) end))
    end)
  else error(errfmt(2,false,_u91,_u92))
  end
end
local fillBreak = function(_u94,_u95)
  if type(_u94) == 'number' and isDoc(_u95) then
    return width(_u95
                ,function(_u93)
                  if _u93>_u94 then return nest(_u94,linebreak)
                  else return text(spaces(_u94-_u93))
                  end
                end)
  else error(errfmt(2,false,_u94,_u95))
  end
end
local fill = function(_u97,_u98)
  if type(_u97) == 'number' and isDoc(_u98) then
    return width(_u98
                ,function(_u96)
                  if _u96 >= _u97 then return empty
                  else return text(spaces(_u97-_u96))
                  end
                end)
  else error(errfmt(2,false,_u97,_u98))
  end
end
local FL,BR = {'Flat'},{'Break'}
local function layout(_u110,_u111,_u112)
  if isDoc(_u110) then
    _u111 = _u111 or 160
    _u112 = _u112 or 0.8
    local ribbon = max(min((_u111*_u112),_u111),0)
    local function fits(_u99,_u100,_u101)
      if _u99<0 then return false
      else
        if '<#null>' == _u101 then return true
        else
          if type(_u101) == 'table' and #_u101 == 2 and
             type(_u101[1]) == 'table' and #_u101[1] == 3
          then
            if _u101[1][3] == Empty then return fits(_u99,_u100,_u101[2])
            else
              if type(_u101[1][3]) == 'table' then
                if #_u101[1][3] == 2 then
                  if _u101[1][3].tag ~= nil then
                    if _u101[1][3].tag == 'Cat' then
                      return fits(_u99
                                 ,_u100
                                 ,{{_u101[1][1];_u101[1][2];_u101[1][3][1]}
                                  ;{{_u101[1][1];_u101[1][2];_u101[1][3][2]}
                                   ;_u101[2]}})
                    else
                      if _u101[1][3].tag == 'Nest' then
                        return fits(_u99
                                   ,_u100
                                   ,{{_u101[1][1]+_u101[1][3][1]
                                     ;_u101[1][2]
                                     ;_u101[1][3][2]}
                                    ;_u101[2]})
                      else return error(tostring(_u101))
                      end
                    end
                  else return error(tostring(_u101))
                  end
                else
                  if #_u101[1][3] == 1 and _u101[1][3].tag ~= nil then
                    if _u101[1][3].tag == 'Text' then
                      return fits(_u99-#_u101[1][3][1]
                                 ,_u100+#_u101[1][3][1]
                                 ,_u101[2])
                    else
                      if _u101[1][2] == FL then
                        if _u101[1][3].tag == 'Break' then
                          return fits(_u99-#_u101[1][3][1]
                                     ,_u100+#_u101[1][3][1]
                                     ,_u101[2])
                        else
                          if _u101[1][3].tag == 'Group' then
                            return fits(_u99
                                       ,_u100
                                       ,{{_u101[1][1]
                                         ;_u101[1][2]
                                         ;_u101[1][3][1]}
                                        ;_u101[2]})
                          else
                            if _u101[1][3].tag == 'Column' then
                              return fits(_u99
                                         ,_u100
                                         ,{{_u101[1][1]
                                           ;_u101[1][2]
                                           ;_u101[1][3][1](_u100)}
                                          ;_u101[2]})
                            else
                              if _u101[1][3].tag == 'Nesting' then
                                return fits(_u99
                                           ,_u100
                                           ,{{_u101[1][1]
                                             ;_u101[1][2]
                                             ;_u101[1][3][1](_u101[1][1])}
                                            ;_u101[2]})
                              else return error(tostring(_u101))
                              end
                            end
                          end
                        end
                      else
                        if _u101[1][2] == BR and _u101[1][3].tag == 'Break'
                        then
                          return true
                        else
                          if _u101[1][3].tag == 'Group' then
                            return fits(_u99
                                       ,_u100
                                       ,{{_u101[1][1]
                                         ;_u101[1][2]
                                         ;_u101[1][3][1]}
                                        ;_u101[2]})
                          else
                            if _u101[1][3].tag == 'Column' then
                              return fits(_u99
                                         ,_u100
                                         ,{{_u101[1][1]
                                           ;_u101[1][2]
                                           ;_u101[1][3][1](_u100)}
                                          ;_u101[2]})
                            else
                              if _u101[1][3].tag == 'Nesting' then
                                return fits(_u99
                                           ,_u100
                                           ,{{_u101[1][1]
                                             ;_u101[1][2]
                                             ;_u101[1][3][1](_u101[1][1])}
                                            ;_u101[2]})
                              else return error(tostring(_u101))
                              end
                            end
                          end
                        end
                      end
                    end
                  else return error(tostring(_u101))
                  end
                end
              else return error(tostring(_u101))
              end
            end
          else return error(tostring(_u101))
          end
        end
      end
    end
    local function push(_u102,_u103)
      _u102[#_u102+1] = _u103
      return _u102
    end
    local function nl(_u104,_u105)
      return push(_u104,('\n'..spaces(_u105)))
    end
    local function best(_u106,_u107,_u108,_u109)
      if '<#null>' == _u109 then return _u106
      else
        if type(_u109) == 'table' and #_u109 == 2 and
           type(_u109[1]) == 'table' and #_u109[1] == 3
        then
          if _u109[1][3] == Empty then
            return best(_u106,_u107,_u108,_u109[2])
          else
            if type(_u109[1][3]) == 'table' then
              if #_u109[1][3] == 2 then
                if _u109[1][3].tag ~= nil then
                  if _u109[1][3].tag == 'Cat' then
                    return best(_u106
                               ,_u107
                               ,_u108
                               ,{{_u109[1][1];_u109[1][2];_u109[1][3][1]}
                                ;{{_u109[1][1];_u109[1][2];_u109[1][3][2]}
                                 ;_u109[2]}})
                  else
                    if _u109[1][3].tag == 'Nest' then
                      return best(_u106
                                 ,_u107
                                 ,_u108
                                 ,{{_u109[1][1]+_u109[1][3][1]
                                   ;_u109[1][2]
                                   ;_u109[1][3][2]}
                                  ;_u109[2]})
                    else error(errfmt(4,false,_u106,_u107,_u108,_u109))
                    end
                  end
                else error(errfmt(4,false,_u106,_u107,_u108,_u109))
                end
              else
                if #_u109[1][3] == 1 and _u109[1][3].tag ~= nil then
                  if _u109[1][3].tag == 'Text' then
                    return best(push(_u106,_u109[1][3][1])
                               ,_u107
                               ,_u108+#_u109[1][3][1]
                               ,_u109[2])
                  else
                    if _u109[1][2] == FL then
                      if _u109[1][3].tag == 'Break' then
                        return best(push(_u106,_u109[1][3][1])
                                   ,_u107
                                   ,_u108+#_u109[1][3][1]
                                   ,_u109[2])
                      else
                        if _u109[1][3].tag == 'Group' then
                          return best(_u106
                                     ,_u111
                                     ,_u108
                                     ,{{_u109[1][1];FL;_u109[1][3][1]}
                                      ;_u109[2]})
                        else
                          if _u109[1][3].tag == 'Column' then
                            return best(_u106
                                       ,_u107
                                       ,_u108
                                       ,{{_u109[1][1]
                                         ;_u109[1][2]
                                         ;_u109[1][3][1](_u108)}
                                        ;_u109[2]})
                          else
                            if _u109[1][3].tag == 'Nesting' then
                              return best(_u106
                                         ,_u107
                                         ,_u108
                                         ,{{_u109[1][1]
                                           ;_u109[1][2]
                                           ;_u109[1][3][1](_u109[1][1])}
                                          ;_u109[2]})
                            else
                              error(errfmt(4,false,_u106,_u107,_u108,_u109))
                            end
                          end
                        end
                      end
                    else
                      if _u109[1][2] == BR then
                        if _u109[1][3].tag == 'Break' then
                          return best(nl(_u106,_u109[1][1])
                                     ,_u109[1][1]
                                     ,_u109[1][1]
                                     ,_u109[2])
                        else
                          if _u109[1][3].tag == 'Group' then
                            do
                              local ribbonleft = min((_u111-_u108)
                                                    ,(ribbon-_u108+_u107))
                              if fits(ribbonleft
                                     ,_u108
                                     ,{{_u109[1][1];FL;_u109[1][3][1]}
                                      ;_u109[2]})
                              then
                                return best(_u106
                                           ,_u107
                                           ,_u108
                                           ,{{_u109[1][1];FL;_u109[1][3][1]}
                                            ;_u109[2]})
                              else
                                return best(_u106
                                           ,_u107
                                           ,_u108
                                           ,{{_u109[1][1];BR;_u109[1][3][1]}
                                            ;_u109[2]})
                              end
                            end
                          else
                            if _u109[1][3].tag == 'Column' then
                              return best(_u106
                                         ,_u107
                                         ,_u108
                                         ,{{_u109[1][1]
                                           ;_u109[1][2]
                                           ;_u109[1][3][1](_u108)}
                                          ;_u109[2]})
                            else
                              if _u109[1][3].tag == 'Nesting' then
                                return best(_u106
                                           ,_u107
                                           ,_u108
                                           ,{{_u109[1][1]
                                             ;_u109[1][2]
                                             ;_u109[1][3][1](_u109[1][1])}
                                            ;_u109[2]})
                              else
                                error(errfmt(4
                                            ,false
                                            ,_u106
                                            ,_u107
                                            ,_u108
                                            ,_u109))
                              end
                            end
                          end
                        end
                      else
                        if _u109[1][3].tag == 'Column' then
                          return best(_u106
                                     ,_u107
                                     ,_u108
                                     ,{{_u109[1][1]
                                       ;_u109[1][2]
                                       ;_u109[1][3][1](_u108)}
                                      ;_u109[2]})
                        else
                          if _u109[1][3].tag == 'Nesting' then
                            return best(_u106
                                       ,_u107
                                       ,_u108
                                       ,{{_u109[1][1]
                                         ;_u109[1][2]
                                         ;_u109[1][3][1](_u109[1][1])}
                                        ;_u109[2]})
                          else error(errfmt(4,false,_u106,_u107,_u108,_u109))
                          end
                        end
                      end
                    end
                  end
                else error(errfmt(4,false,_u106,_u107,_u108,_u109))
                end
              end
            else error(errfmt(4,false,_u106,_u107,_u108,_u109))
            end
          end
        else error(errfmt(4,false,_u106,_u107,_u108,_u109))
        end
      end
    end
    return table.concat(best({},0,0,{{0;BR;_u110};'<#null>'}))
  else error(errfmt(3,false,_u110,_u111,_u112))
  end
end
local zpp = {}
zpp.__index = zpp
zpp.layout = layout
zpp.isDoc = isDoc
zpp.empty = empty
zpp.text = text
zpp.nest = nest
zpp.group = group
zpp.column = column
zpp.nesting = nesting
zpp.line = line
zpp.linebreak = linebreak
zpp.softline = group(line)
zpp.softbreak = group(linebreak)
zpp.space = space
zpp.cat = cat
zpp.catspace = catspace
zpp.abovespace = abovespace
zpp.above = above
zpp.abovesoftspace = abovesoftspace
zpp.abovesoft = abovesoft
zpp.lparen = text'('
zpp.rparen = text')'
zpp.langle = text'<'
zpp.rangle = text'>'
zpp.lbrace = text'{'
zpp.rbrace = text'}'
zpp.lbracket = text'['
zpp.rbracket = text']'
zpp.backtick = text'`'
zpp.squote = text"'"
zpp.dquote = text'"'
zpp.semi = text';'
zpp.colon = text':'
zpp.comma = text','
zpp.dot = text'.'
zpp.slash = text'/'
zpp.backslash = text'\\'
zpp.assign = text'='
zpp.foldDoc = foldDoc
zpp.separateWith = separateWith
zpp.ifoldDoc = ifoldDoc
zpp.iseparateWith = iseparateWith
zpp.indent = indent
zpp.align = align
zpp.hang = hang
zpp.fill = fill
zpp.fillBreak = fillBreak
Doc_mt.type = (function() return "Doc" end)
Doc_mt.__tostring = layout
Doc_mt.__add = cat
Doc_mt.__sub = catspace
Doc_mt.__div = abovespace
Doc_mt.__mul = above
zpp.compose = compose
zpp.identity = identity
zpp.i2list = i2list

-- luapp
local pairs = pairs
local ipairs = ipairs
local find = string.find
local sort = table.sort
local insert = table.insert
local lbracket = zpp.lbracket
local rbracket = zpp.rbracket
local langle = zpp.langle
local rangle = zpp.rangle
local dot = zpp.dot
local assign = zpp.assign
local backtick = zpp.backtick
local dcolon = text" ::"
local consnull = text"[]"
local consnullsp = text" [] "
local TAG = 'tag'
local function encloseSep(_u2,_u3,_u4)
  if isDoc(_u2) and isDoc(_u3) and isDoc(_u4) then
    return function(_u1)
      if type(_u1) == 'table' then
        return _u2+align(group(iseparateWith(_u4+line
                                            ,identity)(_u1)))+_u3
      else error(errfmt(1,false,_u1))
      end
    end
  else error(errfmt(3,false,_u2,_u3,_u4))
  end
end
local tabled = encloseSep(zpp.lbrace,zpp.rbrace,zpp.comma)
local listed_proper = encloseSep(zpp.lbracket
                                ,zpp.rbracket
                                ,zpp.comma)
local function listed(_u5,_u6)
  if _u6 == nil then return listed_proper(_u5)
  else
    return encloseSep(empty,empty,dcolon){listed_proper(_u5);_u6}
  end
end
local angles = function(x) return langle+x+rangle end
local brackets = function(x) return lbracket+x+rbracket end
local brkangles = function(x)
  return lbracket+langle+x+rangle+rbracket
end
local function lua2doc(_u27,_u28)
  if _u28 == nil or type(_u28) == 'string' then
    local root_path = text(_u28 or '<#>')
    local key,value
    local tracker = {}
    local function isLikeId(_u7)
      return type(_u7) == 'string' and find(_u7,"^[%a_][%a%d_]*$")
    end
    local function sort_pairs_by_key(_u10,_u11)
      if type(_u10) == 'table' and #_u10 == 2 and
         type(_u11) == 'table' and #_u11 == 2
      then
        do
          local _u8,_u9 = _u10[1],_u11[1]
          if type(_u8) == 'number' then
            if type(_u9) == 'number' then return _u8<_u9
            else return true
            end
          else
            if type(_u8) == 'string' then
              if type(_u9) == 'string' then return _u8<_u9
              else return not (type(_u9) == 'number')
              end
            else
              if type(_u9) == 'string' or type(_u9) == 'number' then
                return false
              else return type(_u8)<type(_u9)
              end
            end
          end
        end
      else error(errfmt(2,false,_u10,_u11))
      end
    end
    local function str2doc(_u12)
      return text(format("%q",_u12))
    end
    local function render_path(_u13)
      if _u13 == nil then return empty
      else
        local res = empty; for i=#_u13,1,-1 do res = res+_u13[i]; end
        return res
      end
    end
    local function get_addr(_u14)
      local obj = tostring(_u14)
      local _,_,addr = find(obj,': (.+)$')
      return addr or obj
    end
    local function prepare_table(_u17)
      if type(_u17) == 'table' then
        local res,tag,len = {},nil,0
        for i,_ in ipairs(_u17) do len = i; end
        for k,v in pairs(_u17) do
          do
            local _u15,_u16 = k,v
            if _u15 == TAG and type(_u16) == 'string' then tag = _u16
            else insert(res,{k;v})
            end
          end
        end
        sort(res,sort_pairs_by_key)
        tag = tag and backtick+text(tag) or empty
        return len,res,tag
      else error(errfmt(1,false,_u17))
      end
    end
    local function render_nonarray_part(_u18,_u19,_u20,...)
      local last_i = _u18
      for i=_u18,#_u19 do
        last_i = i
        local sorted_k,sorted_v = _u19[i][1],_u19[i][2]
        if sorted_k == 1 then break end
        local new_key,is_id = key(sorted_k)
        local new_path_el = is_id and dot+new_key or new_key
        _u20[i] = (new_key+assign+value(sorted_v,new_path_el,...))
      end
      return last_i
    end
    local function table2doc(_u22,...)
      if type(_u22) == 'table' then
        local length,sorted,tag = prepare_table(_u22)
        local res = {}
        local ii = 1
        do
          local _u21 = sorted
          if type(_u21) == 'table' and #_u21 >= 1 and
             type(_u21[1]) == 'table' and #_u21[1] == 2 and
             type(_u21[1][1]) == 'number' and _u21[1][1] ~= 1
          then
            ii = render_nonarray_part(ii,sorted,res,...)
          else
          end
        end
        for i=ii,ii+length-1 do
          res[i] = value((sorted[i] or {})[2],key(i),...)
        end
        render_nonarray_part(ii+length,sorted,res,...)
        return tag+tabled(res)
      else error(errfmt(1,true,_u22,...))
      end
    end
    local function list2doc(_u23,_u24,...)
      if '<#null>' == _u23 then return _u24
      else
        if type(_u23) == 'table' and #_u23 == 2 then
          do
            _u24[#_u24+1] = value(_u23[1],key(1),...)
            return list2doc(_u23[2],_u24,key(2),...)
          end
        else return _u24,value(_u23,...)
        end
      end
    end
    function key(_u25)
      if type(_u25) == 'table' then
        if #_u25 == 2 and ('<#null>' == _u25[2] or
           type(_u25[2]) == 'table' and #_u25[2] == 2)
        then
          return brkangles(text('pair: '..get_addr(_u25)))
        else return brkangles(text(_u25))
        end
      else
        if type(_u25) == 'number' then return brackets(text(_u25))
        else
          if '<#null>' == _u25 then return brackets(consnullsp)
          else
            if isLikeId(_u25) then return text(_u25),"ID"
            else
              if type(_u25) == 'string' then return brackets(str2doc(_u25))
              else
                if _u25 == nil then return error'nil key?'
                else return brkangles(text(_u25))
                end
              end
            end
          end
        end
      end
    end
    function value(_u26,...)
      if type(_u26) == 'table' then
        if RESPECT_TOSTRING_MT and _u26.__tostring then return text(tostring(_u26)) end
        if tracker[_u26] then return tracker[_u26]
        else
          if #_u26 == 2 and ('<#null>' == _u26[2] and not _u26[TAG] or
             type(_u26[2]) == 'table' and #_u26[2] == 2 and not _u26[TAG])
          then
            do
              tracker[_u26] = render_path{...}
              return listed(list2doc(_u26,{},...))
            end
          else
            do
              tracker[_u26] = render_path{...}
              return table2doc(_u26,...)
            end
          end
        end
      else
        if '<#null>' == _u26 then return consnull
        else
          if type(_u26) == 'string' then return str2doc(_u26)
          else
            if type(_u26) == 'function' or type(_u26) == 'thread' or
               type(_u26) == 'userdata'
            then
              return angles(text(_u26))
            else return text(_u26)
            end
          end
        end
      end
    end
    return value(_u27,root_path)
  else error(errfmt(2,false,_u27,_u28))
  end
end

-- pp(any, [root-name]="<#>", [page-width]=160, [line-fill]=0.8) -> string
-- @root-name -- optional name for the topmost table if you expect it to be recvursive
-- @page-width -- optional max page width
-- @line-fill -- max desired (line width)/(page width)
local function pp(obj, root, width, fill)
  if root == nil or type(root) == 'string' and width == nil or
     type(width) == 'number' and (fill == nil or
     type(fill) == 'number')
  then
    return layout(lua2doc(obj,root),width,fill)
  else error(errfmt(4,false,obj,root,width,fill))
  end
end

local luapp = {}
luapp.__index = luapp
luapp.pp = pp
luapp.zpp = zpp -- submodule, pretty printers construction kit
luapp.errfmt = function(...)
  return errfmt(select("#", ...), false, ...)
end
return luapp