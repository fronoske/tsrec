#!/usr/bin/env ruby
#;;; -*- coding: utf-8; tab-width: 2; -*-

# TODO
# 番組情報.json の出力（番組情報の数値を文字列化）
# Ctrl+C のトラップ（正常終了させる）
# サービスIDでなくチャンネル指定で複数局録画

require 'open-uri'
require 'json'
require 'awesome_print'
require 'logger'
require 'optparse'
require 'fileutils'
require 'pry'

=begin

FORMAT
strftimeに従う。その他
%%T ... タイトル
★TODO
%%S ... サービス名（ＮＨＫ総合１・東京） 
%%s ... ServiceId（1024）

番組情報
ジャンル、コンポーネントの定義はここ
https://github.com/youzaka/ariblib/blob/488ad38bbc54dc2544391d120a95f75dfcf32902/ariblib/constants.py
見やすい表
https://350ml.net/labo/iepg2.html
=end

UA = 'tsrec'
DEFAULT_MIRAKC_HOST = 'localhost'
DEFAULT_MIRAKC_PORT = 40772
DEFAULT_MARGIN_SEC = 5
DEFAULT_OUTFILE_FORMAT = "%Y%m%d_%H%M %%T.ts"
MARGIN_SEC_FOR_NEXT_REC = 60 # 番組終了 n 秒前に次の番組のEPG情報を取得する
RE_BLACK_LIST = [/^放送(休止|終了)$/, /^休止$/]

##################
# Classes
##################
class Program
  attr_accessor :env, :pid, :end_at
  
  def initialize(hash)
    @title = hash[:name]
    @start_at = Time.at(hash[:startAt]/1000)
    @start_at_s = @start_at.strftime("%Y-%m-%d %H:%M:%S")
    @rec_start_at = @start_at - $opt_margin_sec
    @rec_start_at_s = @rec_start_at.strftime("%Y-%m-%d %H:%M:%S")
    @duration = hash[:duration] / 1000
    @end_at = @start_at + @duration
    @end_at_s = @end_at.strftime("%Y-%m-%d %H:%M:%S")
    @program_id = hash[:id]
    @event_id = hash[:eventId]
    @service_id = hash[:serviceId]
    @network_id = hash[:networkId]
    @service_name = SERVICE[:name]
    @service_channel = SERVICE[:channel]
    @service_type    = SERVICE[:type]
    @desc       = hash[:description]
    @extended   = hash[:extended]&.map{|k, v| "#{k}：#{v}"}&.join("\n")
    
    @video_sc   = hash.dig(:video, :streamContent)
    @video_ct   = hash.dig(:video, :componentType)
    @video_ct_s = ARIB_TABLE.dig("ComponentType", @video_sc, @video_ct)
    @video_type = hash.dig(:video, :type).upcase
    @audio_ct   = hash.dig(:audio, :componentType)
    @audio_ct_s = ARIB_TABLE.dig("ComponentType", 2, @audio_ct)
    @audio_rate = hash.dig(:audio, :samplingRate)
    @genres     = hash.dig(:genres).map{|g| [ g[:lv1], g[:lv2] ]}
    @genres_s   = @genres.map{|g| [ARIB_TABLE.dig("ContentType", g[0], "name"), ARIB_TABLE.dig("ContentType", g[0], g[1])]}
    
    show_info if $opt_debug
    
    unless set_path
      $log.error "[FATAL] 出力パスを設定できませんでした: #{@full_path}"
      abort "[FATAL] 出力パスを設定できませんでした: #{@full_path}"
    end
    $log.debug "File: #{@file_name}"
    $log.debug "Path: #{@full_path}"
    @command = 
    case [@full_path.is_a?(String), $opt_pipe.is_a?(String)]
    when [true, true] # ファイル出力 & パイプあり
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream | tee '#{@full_path}' | '#{$opt_pipe}'!
    when [true, false] # ファイル出力 & パイプなし
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream -o '#{@full_path}'!
    when [false, true] # ファイル出力なし & パイプあり
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream | '#{$opt_pipe}'!
    else # [false, false]
      raise "予期しないエラー：@full_path も $opt_pipe も false"
    end
    if $opt_after_rec_command
      @command = "( #{@command} ) && ( #{$opt_after_rec_command} )"
    end

    @env = {
      "TSREC_TITLE" => @tilte.to_s,
      "TSREC_START_AT_Y" => @start_at.year.to_s,
      "TSREC_START_AT_M" => @start_at.month.to_s,
      "TSREC_START_AT_M2" => @start_at.strftime("%m"),
      "TSREC_START_AT_D" => @start_at.day.to_s,
      "TSREC_START_AT_D2" => @start_at.strftime("%d"),
      "TSREC_START_AT_W" =>  @start_at.wday.to_s, # 0(Sun) - 6(Sat)
      "TSREC_START_AT_H" => @start_at.hour.to_s,
      "TSREC_START_AT_H2" => @start_at.strftime("%H"),
      "TSREC_START_AT_MIN" => @start_at.min.to_s,
      "TSREC_START_AT_MIN2" => @start_at.strftime("%M"),
      "TSREC_END_AT_Y" => @end_at.year.to_s,
      "TSREC_END_AT_M" => @end_at.month.to_s,
      "TSREC_END_AT_M2" => @end_at.strftime("%m"),
      "TSREC_END_AT_D" => @end_at.day.to_s,
      "TSREC_END_AT_D2" => @end_at.strftime("%d"),
      "TSREC_END_AT_W" =>  @end_at.wday.to_s, # 0(Sun) - 6(Sat)
      "TSREC_END_AT_H" => @end_at.hour.to_s,
      "TSREC_END_AT_H2" => @end_at.strftime("%H"),
      "TSREC_END_AT_MIN" => @end_at.min.to_s,
      "TSREC_END_AT_MIN2" => @end_at.strftime("%M"),
      "TSREC_DURATION_SEC" => @duration.to_s,
      "TSREC_PROGRAM_ID" => @program_id.to_s,
      "TSREC_EVENT_ID" => @event_id.to_s,
      "TSREC_SERVICE_ID" => @service_id.to_s,
      "TSREC_SERVICE_NAME" => @service_name.to_s,
      "TSREC_SERVICE_CHANNEL" => @service_channel.to_s,
      "TSREC_SERVICE_TYPE" => @service_type.to_s,
      "TSREC_NETWORK_ID" => @network_id.to_s,
      "TSREC_DESC" => @desc.to_s,
      "TSREC_EXTENDED" => @extended.to_s.gsub("\n", "\\n"),
      "TSREC_OUT_PATH" => @full_path.to_s,
      "TSREC_OUT_PATH_BASE" => @full_path.to_s.gsub(/\..+?$/, ''),
      "TSREC_OUT_DIR" => $out_dir.to_s,
      "TSREC_OUT_BASE" => File.basename(@file_name, ".*"),
      "TSREC_OUT_EXT" => File.extname(@file_name),
      "TSREC_VIDEO_STREAM" => @video_sc.to_s,
      "TSREC_VIDEO_COMPONENT"  => @video_ct.to_s,
      "TSREC_VIDEO_COMPONENT_S"  => @video_ct_s.to_s,
      "TSREC_VIDEO_TYPE" => @video_type.to_s,
      "TSREC_AUDIO_COMPONENT" => @audio_ct.to_s,
      "TSREC_AUDIO_COMPONENT_S" => @audio_ct_s.to_s,
      "TSREC_AUDIO_RATE" => @audio_rate.to_s,
      "TSREC_GENRE1"    => @genres_s.dig(0, 0).to_s,
      "TSREC_GENRE1SUB" => @genres_s.dig(0, 1).to_s,
      "TSREC_GENRE2"    => @genres_s.dig(1, 0).to_s,
      "TSREC_GENRE2SUB" => @genres_s.dig(1, 1).to_s,
      "TSREC_GENRE3"    => @genres_s.dig(2, 0).to_s,
      "TSREC_GENRE3SUB" => @genres_s.dig(2, 1).to_s,
      "TSREC_GENRE4"    => @genres_s.dig(3, 0).to_s,
      "TSREC_GENRE4SUB" => @genres_s.dig(3, 1).to_s,
    }
  end
  
  def set_path
    format_base = File.basename($opt_outfile_format, ".*")
    format_ext  = File.extname($opt_outfile_format)
    0.upto(999) do |idx|
      postfix = (idx == 0) ? "" : "(#{idx})"
      format = "#{format_base}#{postfix}#{format_ext}"
      @file_name = @start_at.strftime(format).gsub('%T', @title)
      @file_name = sanitize(@file_name)
      @full_path = $opt_out_dir ? File.join($opt_out_dir, @file_name) : nil
      return true if $opt_out_dir.nil? || !File.exist?(@full_path)
    end
    return false
  end
  
  # 録画を待機する
  def wait_rec_start
    sec_to_rec_start = [0, @rec_start_at - Time.now ].max
    $log.info "次の番組の録画を準備します"
    $log.info "次の番組：#{@start_at_s}「#{@title}」（#{sec2hhmmss(@duration)}）"
    $log.info "録画時刻：#{@rec_start_at_s}"
    $log.info "録画を待機します（待ち時間：#{sec2hhmmss(sec_to_rec_start.to_i)}）"
    $log.debug "コマンド：#{@command}"
    sleep(sec_to_rec_start)
  end
  
  # 録画を実行する
  def do_rec
    $log.debug @command
    @pid = spawn(@env, @command)
    $log.info "録画を開始しました (Process ID: #{@pid})"
  rescue
    $log.error "[FATAL] curlコマンドの呼び出しに失敗しました。終了します。"
    $log.error $!
    $log.error $!.backtrace
    abort "[FATAL] curlコマンドの呼び出しに失敗しました。終了します。"
  end
  
  # 録画終了の寸前まで待つ
  def wait_rec_end
    sec_to_rec_end = [0, $opt_margin_sec + @duration - MARGIN_SEC_FOR_NEXT_REC].max
    # $log.info "終了#{MARGIN_SEC_FOR_NEXT_REC}秒前に次の録画を準備します"
    $log.info "現在の番組の終了予定：#{@end_at_s}"
    $log.info "現在の番組の終了を待機します（待ち時間：#{sec2hhmmss(sec_to_rec_end.to_i)}）"
    sleep(sec_to_rec_end)
  end
  
  def generate_program_info
    return nil if @full_path
    attrs = %s(@title @event_id @network_id @service_id @service_name @service_channel @service_type @start_at @end_at @duration
      @video_ct @video_ct_s @video_type @audio_ct @audio_ct_s @audio_rate @genres_s @desc @extended)
    if $opt_output_json
      obj = attrs.map{|att| val = self.instance_variable_get(att); [key,val]}.to_h
      json_body = JSON.pretty_generate(obj)
      json_path = @full_path.gsub(/\..+?$/, '.json')
      open(json_path, "w"){|f| f.puts json_body}
    else
      lines = []
      lines << "#{to_j(@start_at, @end_at)} (#{sec2hhmmss(@duration)})"
      lines << "#{@service_name}"
      lines << "#{@title}"
      lines << ""
      lines << "#{@desc}"
      lines << ""
      lines << "【詳細情報】"
      lines << "#{@extended}"
      lines << ""
      lines << "【ジャンル】"
      lines << @genres_s.map{|genre_mainsub| genre_mainsub.join(" - ")}.join("\n")
      lines << ""
      lines << "映像：#{@video_ct_s}"
      lines << "音声：#{@audio_ct_s}"
      lines << "サンプリングレート：#{@audio_rate}"
      lines << ""
      lines << "NetworkId: #{@network_id}"
      lines << "ServiceId: #{@service_id}"
      lines << "EventId: #{@event_id}"
      text_body = lines.map(&:strip).join("\n")
      text_path = @full_path.gsub(/\..+?$/, '.txt')
      open(text_path, "w"){|f| f.puts text_body}
    end

    def to_j(start_at, end_at)
      wday_j = "日月火水木金土"[start_at.wday]
      start_s = start_at.strftime("%y/%m/%d(#{wday_j}) %H:%M") 
      end_s = end_at.strftime("%H:%M") 
      if start_at.day != end_at.day
        if end_at.hour < 6
          end_s.gsub!(/^\d\d:/, "#{end_at.hour + 24}:")
	else
          wday_j = "日月火水木金土"[end_at.wday]
          end_s = end_at.strftime("%y/%m/%d(#{wday_j}) %H:%M")
        end
      end
      "#{start_s}～#{end_s}" 
    end
  end
  
  # Windows のファイル名に使用できない文字を全角にする。「！」は使用できるが「？」とのバランスのため。
  def sanitize(str)
    str.tr('\\\/:*!?"<>|', '￥／：＊！？＜＞｜')
  end 
  def sec2hhmmss(sec)
    "%02d:%02d:%02d" % [sec/3600, (sec%3600)/60, sec%60]
  end
  
  def show_info
    self.pretty_print_instance_variables.each do |_var|
      _val = instance_variable_get(_var)
      $log.debug "<#{_var}> #{_val}"
    end
  end
end


##################
# Functions
##################
def get_future_programs(service_id, time=Time.now)
  unix_time = time.to_i
  programs = JSON.parse(URI.open("#{BASE_URL}/programs", "r:utf-8", nil, {"User-Agent" => UA}).read, symbolize_names: true)
  programs_by_service = programs.select{|prog| prog[:serviceId] == service_id}
  future_programs = programs_by_service.select{|prog| prog[:startAt] > unix_time * 1000}
  future_programs.reject!{|prog| prog[:name] =~ Regexp.union(*RE_BLACK_LIST)}
  future_programs.sort_by!{|prog| prog[:startAt]}
  future_programs
rescue
  $Log.error "[FATAL] 番組リストの取得に失敗しました。終了します。"
  $Log.error $!
  $Log.error $!.backtrace
  abort "[FATAL] 番組リストの取得に失敗しました。終了します。"
end

def main
  process_list = []
  program_hash = get_future_programs($opt_service_id)&.first
  program = Program.new(program_hash)
  program.wait_rec_start
  program.generate_program_info
  program.do_rec
  process_list << {pid: program.pid, end_at: program.end_at}
  process_list.select!{|process| File.exist?("/proc/#{process[:pid]}")}
  zombees = process_list.select{|process| process[:end_at] + 10 < Time.now}
  $log.warn "録画プロセスが終了時刻になっても録画を終了していません [PID: #{zombees.join(',')}]" unless zombees.empty?
  program.wait_rec_end
end

def get_services
  channels_json = File.expand_path("../channels.json", $0)
  unless File.exist?(channels_json)
    system("curl #{BASE_URL}/channels -o #{channels_json}")
  end
  channels = JSON.parse(open(channels_json, "r:utf-8").read, symbolize_names: true)
  channels.map{|c|
  type = c[:type]
  ch   = c[:channel]
    c[:services].map{|s| s.merge({type: type, channel: ch})}
  }.flatten.uniq.sort_by{|s| [['GR', 'BS', 'CS'].index(s[:type]), s[:serviceId]]}
rescue
  $log.warn "サービス一覧の取得に失敗しました。続行します。"
  []
end

def show_services
  w = -> s { s.codepoints.inject(0) { |a, e| a + (e < 256 ? 1 : 2) } }
  type = $opt_show_services_list.to_s.upcase[/GR|BS|CS|ALL/]
  puts "     サービス名      サービスID  タイプ  物理ch"
  SERVICES.select{|sv| type == 'ALL' || sv[:type] == type}.each do |sv|
    name = sv[:name]
    sid  = sv[:serviceId].to_s
    type = sv[:type]
    ch   = sv[:channel].to_s
    padding = " " * (22 - w[name])
    puts "%s  %5s      %2s    %6s" % ["#{name}#{padding}", sid, type, ch]
  end
  puts
end

def get_arib_table
  arib_yaml = File.expand_path("../arib-constants.yaml", $0)
  if File.exist?(arib_yaml)
    YAML.load_file(arib_yaml)
  else
    {}
  end
end

###########################
# Start Here
###########################
opts = OptionParser.new
opts.define_tail <<EOT

サービス名  NetID  サービスID 物理ch
NHK総合1    32736     1024    27ch
NHK総合2    32736     1025    27ch
Eテレ1      32737     1032    26ch
Eテレ3      32737     1034    26ch
tvk1        32375    24632    18ch
tvk2        32375    24633    18ch
tvk3        32375    24634    18ch
日テレ      32738     1040    25ch
テレビ朝日  32741     1064    24ch
TBS         32739     1048    22ch
テレビ東京  32742     1072    23ch
フジテレビ  32740     1056    21ch
TOKYO MX1   32391    23608    16ch
TOKYO MX2   32391    23610    16ch
イッツコム  32383    24697    30ch

NHK BS1         4      101  BS15_0
BSプレミアム    4      103  BS03_1

EOT
opts.on("-s serviceId",        Integer, "service ID"){|v| $opt_service_id = v}
opts.on("-m marginSec",        Integer, "margin sec to rec (default: #{DEFAULT_MARGIN_SEC})"){|v| $opt_margin_sec = v }
opts.on("-o outDir",           String,  "Output directory"){|v| $opt_out_dir = v}
opts.on("-f outfileFormat",    String,  "out file format (default: #{DEFAULT_OUTFILE_FORMAT})"){|v| $opt_outfile_format = v }
opts.on("-j",                           "Output JSON file instad of text file"){|v| $opt_output_json = v }
opts.on("-p command",          String,  "pipe command"){|v| $opt_pipe = v }
opts.on("-a command",          String,  "command after each rec"){|v| $opt_after_rec_command = v }
opts.on("-d",                           "debug mode"){|v| $opt_debug = v }
opts.on("-l logfile",          String,  "output log (default: stderr)"){|v| $opt_logfile = v }
opts.on("-u host:port",        String,  "mirakc host:port (default: #{DEFAULT_MIRAKC_HOST}:#{DEFAULT_MIRAKC_PORT})"){|v| $opt_mirakc_host, $opt_mirakc_port = v.split(":") }
opts.on("-S [GR|BS|CS|ALL]",   String,  "Show services list"){|v| $opt_show_services_list = v }
opts.parse!(ARGV)
$log = Logger.new($opt_logfile || $stderr)
$log.level = $opt_debug ? Logger::DEBUG : Logger::INFO
$log.formatter = proc{|severity, datetime, progname, message|
  "[%s] [%s] %s\n" % [datetime.strftime('%H:%M:%S'), severity, message ]
}
$opt_margin_sec     ||= DEFAULT_MARGIN_SEC
$opt_outfile_format ||= DEFAULT_OUTFILE_FORMAT
$opt_mirakc_host    ||= DEFAULT_MIRAKC_HOST
$opt_mirakc_port    ||= DEFAULT_MIRAKC_PORT

BASE_URL = "http://#{$opt_mirakc_host}:#{$opt_mirakc_port}/api"
ARIB_TABLE = get_arib_table
SERVICES = get_services

if $opt_show_services_list
  show_services
  exit 0
end

if $opt_service_id.nil?
  puts opts.help
  puts
  abort "[FATAL] サービスIDの指定は必ず必要です\n\n"
end

if $opt_out_dir.nil? && $opt_pipe.nil?
  puts opts.help
  puts
  abort "[FATAL] -o か -p のどちらかは必ず指定する必要があります\n\n"
end

SERVICE = SERVICES.find{|s| s[:serviceId] == $opt_service_id}
if SERVICE
  $log.info "-" * 100
  $log.info "#{SERVICE[:name]} (#{SERVICE[:type]}/#{SERVICE[:channel]}) を全録します"
  $log.info "-" * 100
else
  $log.error "[FATAL] 指定されたサービスが見つかりません。終了します。"
  abort "[FATAL] 指定されたサービスが見つかりません。終了します。"
end

if $opt_out_dir
  $opt_out_dir = File.expand_path($opt_out_dir)
  FileUtils.mkdir_p($opt_out_dir) if $opt_out_dir && !File.directory?($opt_out_dir)
end

while(true) do
  main
end
