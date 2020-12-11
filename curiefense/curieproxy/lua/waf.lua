module(..., package.seeall)

local globals   = require "lua.globals"
local utils     = require "lua.utils"
local libinject = require "lua.resty.libinjection"
local globals   = require "lua.globals"

local luahs     = require "luahs"
local cjson     = require "cjson"

local json_encode   = cjson.encode

local table_length  = utils.table_length


local re_match  = utils.re_match

local libinject_sqli = libinject.sqli
local libinject_xss = libinject.xss

local WAFPass           = globals.WAFPass
local WAFBlock          = globals.WAFBlock
local WAFRustSignatures = globals.WAFRustSignatures
local WAFSignatures     = globals.WAFSignatures


function store_section(master_dict, key, subkey,  value)
    if master_dict[key] then
        master_dict[key][subkey] = value
    else
        master_dict[key] = { [subkey] = value}
    end
end

function build_section(section_name, profile)
    local name_rules, regex_rules, max_len, max_count

    if section_name == "headers" then
        name_rules = profile.headers.names
        regex_rules = profile.headers.regex
        max_count = profile.max_headers_count
        max_len = profile.max_header_length

    elseif section_name == "cookies" then
        name_rules = profile.cookies.names
        regex_rules = profile.cookies.regex
        max_count = profile.max_cookies_count
        max_len = profile.max_cookie_length

    elseif section_name == "args" then
        name_rules = profile.args.names
        regex_rules = profile.args.regex
        max_count = profile.max_args_count
        max_len = profile.max_arg_length
    end

    return {name_rules, regex_rules, max_len, max_count}

end

function gen_block_info(section, name, value, sig)
    return {
        ["initiator"] = 'waf',
        ["section"] = section,
        ["name"] = name,
        ["value"] = value,
        ["sig_id"] = sig.id or '-',
        ["sig_category"] = sig.category or '-',
        ["sig_subcategory"] = sig.subcategory or '-',
        ["sig_severity"] = sig.severity or 5,
        ["sig_certainity"] = sig.certainity or 5,
        ["sig_operand"] = sig.operand or '-',
        ["sig_msg"] = sig.msg or '-'
    }
end

function name_check(section, name, name_rule, value, omit_entries, exclude_sigs)
    local matched = re_match(value, name_rule.reg)

    if matched then
        store_section(omit_entries, section, name, true)
    else
        if name_rule.restrict then
            return  WAFBlock, string.format("(%s)/%s mismatch with %s", section, name_rule.reg, value)
        elseif table_length(name_rule.exclusions)  > 0 then
            store_section(exclude_sigs, section, name, name_rule.exclusions)
        end
    end
    return nil, nil
end

function regex_check(section, name, regex_rules, value, omit_entries, exclude_sigs)

    for name_patt, patt_rule in pairs(regex_rules) do
        if re_match(name, name_patt) then
            local matched = re_match(value, patt_rule.reg)
            if matched then
                store_section(omit_entries, section, name, true)
            else
                if patt_rule.restrict then
                    return WAFBlock, string.format("(%s)/name-patt:%s value-patt:%s mismatch with name: %s value:%s", section, name_patt, patt_rule.reg, name, value)
                elseif table_length(patt_rule.exclusions) > 0 then
                    store_section(exclude_sigs, section, name, patt_rule.exclusions)
                end
            end
        end
    end
    return nil, nil
end

function waf_regulate(section, profile, request, omit_entries, exclude_sigs)
    -- -- request.handle:logDebug("WAF regulation - positive security for section: " .. section)
    local section_rules = build_section(section, profile)

    local name_rules, regex_rules, max_len, max_count = unpack(section_rules)

    local entries = request[section]
    local check_regex = (table_length(regex_rules) > 0)
    local ignore_alphanum = profile.ignore_alphanum
    local num_entries = table_length(entries)

    if num_entries > max_count then
        local msg = string.format("# of entries (%s) in section %s exceeded max value %s", num_entries, section, max_count)
        return WAFBlock, gen_block_info(section, '-', '-', {["msg"] = msg})
    end

    for name, value in pairs(entries) do
        if value then
            local value_len = value:len()
            if value_len > max_len then
                local msg = string.format("Length of %s/%s exceeded. Limit: %s, Got: %s", section, name, max_len, value_len)
                return WAFBlock, gen_block_info(section, name, value, {["msg"] = msg})
            end

            if ignore_alphanum and re_match(value, "^\\w$") then
                store_section(omit_entries, section, name, true)
            else
                name_rule = name_rules[name]
                if name_rule then
                    local response, msg = name_check(section, name, name_rule, value, omit_entries, exclude_sigs)
                    if WAFBlock == response then
                        return response, gen_block_info(section, name, value, {["msg"] = msg})
                    end
                end
                if check_regex then
                    local response, msg = regex_check(section, name, regex_rules, value, omit_entries, exclude_sigs)
                    if WAFBlock == response then
                        return response, gen_block_info(section, name, value, {["msg"] = msg})
                    end
                end
            end
        end
    end

    return WAFPass, {}
end



-- function wafsig_re_match(input, request)
--     return WAFRustSignatures:is_match_ids(input)
-- end


function check(waf_profile, request)
    local omit_entries = {}
    local exclude_sigs = {}
    local sections = {"headers", "cookies", "args"}
    -- local sections = {"args"}

    -- request.handle:logDebug(string.format("WAF inspection starts - with profile %s", waf_profile.name))
    local hca_values = {}

    for _, section in ipairs(sections) do
        -- -- request.handle:logDebug("WAF inspecting section: " .. section)
        -- positive security
        local response, msg = waf_regulate(section, waf_profile, request, omit_entries, exclude_sigs)
        if response == WAFBlock then
            return response, msg
        end
        -- -- request.handle:logInfo(string.format("WAF inspection\nomit_entries: %s\nexclude_sigs: %s", json_encode(omit_entries), json_encode(exclude_sigs)))
        -- negative security
        local r_section = request[section]
        for name, value in pairs(r_section) do
            if omit_entries[section] == nil or (not omit_entries[section][name]) then

                if exclude_sigs[sections] == nil or (exclude_sigs[sections][name] and exclude_sigs[sections][name]["libinjection"] == nil) then
                    local detect, token = detect_sqli(value)
                    if detect then
                        return WAFBlock, gen_block_info(section, name, value,
                            { ["id"] = "libinjection", ["category"] = "sqli", ["subcategory"] = "sqli", ["msg"] = token })
                    end
                    detect, token = detect_xss(value)
                    if detect then
                        return WAFBlock, gen_block_info(section, name, value,
                            { ["id"] = "libinjection", ["category"] = "xss", ["subcategory"] = "xss", ["msg"] = token })
                    end
                end

                table.insert(hca_values, value)
            end
        end
    end

--[[
    -- hyperscan lua
    local matches = globals.WAFHScanDB:scan(hca_values, globals.WAFHScanScratch)

    for k,v in pairs(matches) do
        local matched_sigs = {}
        if type(v) == "table" then
            if v.id then
                table.insert(matched_sigs, v.id)
            end
        end

        if #matched_sigs > 0 then
            local section_exclude_ids = (exclude_sigs[section] and exclude_sigs[section][name]) or {}
            for _, msig in ipairs(matched_sigs) do
                -- request.handle:logInfo(string.format("WAFRustSignatures MATCHED -- iter over %s", msig))
                if not section_exclude_ids[msig] then
                    if globals.WAFSignatures then
                        local waf_sig = globals.WAFSignatures[tostring(msig)]
                        -- request.handle:logInfo(string.format("WAF block by Sig %s", waf_sig.id))
                        return WAFBlock, gen_block_info(section, name, value, waf_sig)
                    end
                end
            end
        end
    end
]]--


    -- hyperscan rust

    local matched_sigs = WAFRustSignatures:is_match_ids(value)
    if matched_sigs then
        -- request.handle:logInfo("WAFRustSignatures MATCHED IDS!")
        local section_exclude_ids = (exclude_sigs[section] and exclude_sigs[section][name]) or {}
        for _, msig in ipairs(matched_sigs) do
            -- request.handle:logInfo(string.format("WAFRustSignatures MATCHED -- iter over %s", msig))
            if not section_exclude_ids[msig] then
                if globals.WAFSignatures then
                    local waf_sig = globals.WAFSignatures[msig]
                    -- request.handle:logInfo(string.format("WAF block by Sig %s", waf_sig.id))
                    return WAFBlock, gen_block_info(section, name, value, waf_sig)
                end
            end
        end
    end


    return WAFPass, "waf-passed"
end

function detect_sqli(input)
    if (type(input) == 'table') then
        for _, v in ipairs(input) do
            local match, value = detect_sqli(v)
            if match then
                return match, value
            end
        end
    else
        return libinject_sqli(input)
    end

    return false, nil
end

function detect_xss(input)
    if (type(input) == 'table') then
        for _, v in ipairs(input) do
            local match, value = detect_xss(v)
            if match then
                return match, value
            end
        end
    else
        return libinject_xss(input)
    end

    return false, nil
end
