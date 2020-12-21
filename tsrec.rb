#!/usr/bin/env ruby
#;;; -*- coding: utf-8; tab-width: 2; -*-

# TODO
# env の確認、パイプのテストなど
# 番組情報.json の出力（番組情報の数値を文字列化）
# Ctrl+C のトラップ（正常終了させる）

require 'open-uri'
require 'json'
require 'awesome_print'
require 'logger'
require 'optparse'
require 'fileutils'
require 'pry'
=begin
- コマンドは zenroku -s serviceId [-o dir] [-m marginSec] [-f "%Y%m%d_%H%M %%T.ts"] [-l logfile] [-p] [-h host:port] みたいな感じ
- 終了しないコマンド。background で動かすイメージ
- marginSec は mirakc の server.stream-time-limit 以内。デフォルトは 5秒。
- -f がなければデフォルト "%Y%m%d_%H%M %T.ts"
- -o がなければファイル出力しない
- -p は標準出力する。パイプ用。 " | ffmpeg -i /dev/stdin ..." みたいな使い方を想定。

コマンド自体のメッセージはすべて標準エラー出力とする

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

DEFAULT_MIRAKC_HOST = 'localhost'
DEFAULT_MIRAKC_PORT = 40772
DEFAULT_MARGIN_SEC = 5
DEFAULT_OUTFILE_FORMAT = "%Y%m%d_%H%M %%T.ts"
MARGIN_SEC_FOR_NEXT_REC = 60 # 番組終了 n 秒前に次の番組のEPG情報を取得する
RE_BLACK_LIST = [/^放送(休止|終了)$/, /^休止$/]

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
    @service_id = hash[:serviceId]
    @network_id = hash[:networkId]
    @desc       = hash[:description]
    @more_desc  = hash[:extended]&.map{|k, v| "#{k}：#{v}"}&.join("\n")
    unless set_path
      $log.error "出力パスを設定できませんでした: #{@full_path}"
      abort
    end
    $log.debug "File: #{@file_name}"
    $log.debug "Path: #{@full_path}"
    @command = 
    case [@full_path.is_a?(String), $opt_pipe.is_a?(String)]
    when [true, true] # ファイル出力 & パイプあり
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream | tee '#{@full_path} | #{$opt_pipe}'!
    when [true, false] # ファイル出力 & パイプなし
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream -o '#{@full_path}'!
    when [false, true] # ファイル出力なし & パイプあり
      %Q!curl -sSL #{BASE_URL}/programs/#{@program_id}/stream | #{$opt_pipe}!
    else # [false, false]
      raise "予期しないエラー：@full_path も $opt_pipe も false"
    end
    
    # 番組情報は後で
    @env = {
      "TSREC_TITLE" => @tilte,
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
      "TSREC_SERVICE_ID" => @service_id.to_s,
      "TSREC_NETWORK_ID" => @network_id.to_s,
      "TSREC_DESC" => @desc,
      "TSREC_EXTENDED" => @more_desc&.gsub("\n", "\\n"),
	  "TSREC_OUT_PATH" => @full_path.to_s,
	  "TSREC_OUT_PATH_BASE" => @full_path.to_s.gsub(/\.+?$/, ''),
	  "TSREC_OUT_DIR" => $out_dir.to_s,
	  "TSREC_OUT_BASE" => File.basename(@file_name, ".*"),
	  "TSREC_OUT_EXT" => File.extname(@file_name),
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
    $log.info "次の番組：#{@start_at_s}「#{@title}」（#{sec2hhmmss(@duration)}）"
    $log.info "録画時刻：#{@rec_start_at_s}"
    $log.info "待ち時間：#{sec2hhmmss(sec_to_rec_start.to_i)}"
    $log.debug "コマンド：#{@command}"
    sleep(sec_to_rec_start)
    $log.info "録画を開始します"
  end
  
  # 録画を実行する
  def do_rec
    $log.debug @command
    @pid = spawn(@env, @command)
    $log.info "Process ID: #{@pid}"
  end
  
  # 録画終了の寸前まで待つ
  def wait_rec_end
    sec_to_rec_end = [0, $opt_margin_sec + @duration - MARGIN_SEC_FOR_NEXT_REC].max
    $log.info "番組終了予定：#{@end_at_s}"
    $log.info "終了#{MARGIN_SEC_FOR_NEXT_REC}秒前に次の録画を準備します"
    $log.info "待ち時間：#{sec2hhmmss(sec_to_rec_end.to_i)}"
    sleep(sec_to_rec_end)
  end
  
  # Windows のファイル名に使用できない文字を全角にする。「！」は使用できるが「？」とのバランスのため。
  def sanitize(str)
    str.tr('\\\/:*!?"<>|', '￥／：＊！？＜＞｜')
  end 
  def sec2hhmmss(sec)
    "%02d:%02d:%02d" % [sec/3600, (sec%3600)/60, sec%60]
  end
end

def get_future_programs(service_id, time=Time.now)
  unix_time = time.to_i
  programs = JSON.parse(URI.open("#{BASE_URL}/programs", "r:utf-8").read, symbolize_names: true)
  programs_by_service = programs.select{|prog| prog[:serviceId] == service_id}
  future_programs = programs_by_service.select{|prog| prog[:startAt] > unix_time * 1000}
  future_programs.reject!{|prog| prog[:name] =~ Regexp.union(*RE_BLACK_LIST)}
  future_programs.sort_by!{|prog| prog[:startAt]}
  future_programs
rescue
  $stderr.puts "番組リストの取得に失敗しました"
  $stderr.puts $!
  $stderr.puts $!.backtrace
  []
end

def main
  process_list = []
  program_hash = get_future_programs($opt_service_id)&.first
  if program_hash.nil?
    $stderr.puts "[ERROR] Failed to get next program"
    abort
  end
  program = Program.new(program_hash)
  program.wait_rec_start
  begin
    program.do_rec
	process_list << {pid: program.pid, end_at: program.end_at}
    process_list.select!{|process| File.exist?("/proc/#{process[:pid]}")}
    zombees = process_list.select{|process| process[:end_at] + 10 < Time.now}
    $log.warn "録画プロセスが終了時刻になっても録画を終了していません [PID: #{zombees.join(',')}]" unless zombees.empty?
  rescue
    $stderr.puts "[FATAL] curlコマンドの実行に失敗しました"
    $stderr.puts $!
    $stderr.puts $!.backtrace
    nil
  end
  program.wait_rec_end
end

def get_services
  unless File.exist?("channels.json")
    system("curl #{BASE_URL}/channels -o channels.json")
  end
  channels = JSON.parse(open("channels.json", "r:utf-8").read, symbolize_names: true)
  channels.map{|c|
	type = c[:type]
	ch   = c[:channel]
    c[:services].map{|s| s.merge({type: type, channel: ch})}
  }.flatten
rescue
  []
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
opts.on("-p command",          String,  "pipe command"){|v| $opt_pipe = v }
opts.on("-d",                           "debug mode"){|v| $opt_debug = v }
opts.on("-l logfile",  String,          "output log (default: stderr)"){|v| $opt_logfile = v }
opts.on("-u mirakc host:port", String,  "mirakc host:port (default: #{DEFAULT_MIRAKC_HOST}:#{DEFAULT_MIRAKC_PORT})"){|v| $opt_mirakc_host, $opt_mirakc_port = v.split(":") }
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
if $opt_service_id.nil?
  puts opts.help
  puts
  abort "サービスIDの指定は必ず必要です\n\n"
end
if $opt_out_dir.nil? && $opt_pipe.nil?
  puts opts.help
  puts
  abort "-o か -p のどちらかは必ず指定する必要があります\n\n"
end

if $opt_out_dir
  $opt_out_dir = File.expand_path($opt_out_dir)
  FileUtils.mkdir_p($opt_out_dir) if $opt_out_dir && !File.directory?($opt_out_dir)
end

BASE_URL = "http://#{$opt_mirakc_host}:#{$opt_mirakc_port}/api"
SERVICES = get_services
SERVICE = SERVICES.find{|s| s[:serviceId] == $opt_service_id}
if SERVICE
  $log.info "#{SERVICE[:name]} (#{SERVICE[:type]}/#{SERVICE[:channel]}) を全録します"
else
  abort "Failed to get target service"
end

while(true) do
  main
end
