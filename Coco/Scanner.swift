/*----------------------------------------------------------------------
    Compiler Generator Coco/R,
    Copyright (c) 1990, 2004 Hanspeter Moessenboeck, University of Linz
    extended by M. Loeberbauer & A. Woess, Univ. of Linz
    with improvements by Pat Terry, Rhodes University
    Swift port by Michael Griebling, Computer Inspirations

    This program is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by the
    Free Software Foundation; either version 2, or (at your option) any
    later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
    for more details.

    You should have received a copy of the GNU General Public License along
    with this program; if not, write to the Free Software Foundation, Inc.,
    59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

    As an exception, it is allowed to write an extension of Coco/R that is
    used as a plugin in non-free software.

    If not otherwise stated, any source code generated by Coco/R (other than
    Coco/R itself) does not fall under the GNU General Public License.
-----------------------------------------------------------------------*/

import Foundation

public class Token {
	public var kind = 0		 // token kind
	public var pos = 0		 // token position in bytes in the source text (starting at 0)
	public var charPos = 0	 // token position in characters in the source text (starting at 0)
	public var col = 0		 // token column (starting at 1)
	public var line = 0		 // token line (starting at 1)
	public var val = ""		 // token value
	public var next: Token?  // ML 2005-03-11 Tokens are kept in linked list
}

extension NSInputStream {
	var CanSeek: Bool { return false }
}

//-----------------------------------------------------------------------------------
// Buffer
//-----------------------------------------------------------------------------------
public class Buffer {
	// This Buffer supports the following cases:
	// 1) seekable stream (file)
	//    a) whole stream in buffer
	//    b) part of stream in buffer
	// 2) non seekable stream (network, console)
	
	public static let EOF = Int(UInt8.max) + 1
	static let MIN_BUFFER_LENGTH = 1024 // 1KB
	let MIN_BUFFER_LENGTH : Int = Buffer.MIN_BUFFER_LENGTH
	let MAX_BUFFER_LENGTH = Buffer.MIN_BUFFER_LENGTH * 64 // 64KB
	var buf : [UInt8]			// input buffer
	var bufStart: Int			// position of first byte in buffer relative to input stream
	var bufLen: Int				// length of buffer
	var fileLen: Int			// length of input stream (may change if the stream is no file)
	var bufPos: Int	= 0			// current position in buffer
	var stream: NSInputStream	// input stream (seekable)
	var isUserStream: Bool		// was the stream opened by the user?
	
	public init (s: NSInputStream, isUserStream: Bool) {
		stream = s; self.isUserStream = isUserStream
		
		if stream.CanSeek {
			fileLen = 0
			bufLen = min(fileLen, MAX_BUFFER_LENGTH)
			bufStart = Int.max // nothing in the buffer so far
		} else {
			fileLen = 0; bufLen = 0; bufStart = 0
		}
		
		buf = [UInt8](count: bufLen>0 ? bufLen : MIN_BUFFER_LENGTH, repeatedValue: 0)
		if (fileLen > 0) { Pos = 0 } // setup buffer to position 0 (start)
		else { bufPos = 0 } // index 0 is already after the file, thus Pos = 0 is invalid
	}
	
	private init (b: Buffer) { // called in UTF8Buffer constructor
		buf = b.buf;
		bufStart = b.bufStart
		bufLen = b.bufLen
		fileLen = b.fileLen
		bufPos = b.bufPos
		stream = b.stream
		// keep destructor from closing the stream
		//		b.stream = null;
		isUserStream = b.isUserStream
	}
	
	public func Read () -> Int {
		if bufPos < bufLen {
			return Int(buf[bufPos++])
		} else if Pos < fileLen {
			return Int(buf[bufPos++])
		} else if !stream.CanSeek && ReadNextStreamChunk() > 0 {
			return Int(buf[bufPos++])
		} else {
			return Buffer.EOF
		}
	}
	
	public func Peek () -> Int {
		let curPos = Pos
		let ch = Read()
		Pos = curPos
		return ch
	}
	
	// beg .. begin, zero-based, inclusive, in byte
	// end .. end, zero-based, exclusive, in byte
	public func GetString (beg: Int, end: Int) -> String {
		var len = 0
		var buf = [CChar](count: end-beg+1, repeatedValue: 0)
		let oldPos = Pos
		Pos = beg
		while Pos < end { buf[len++] = CChar(Read()) }
		Pos = oldPos
		return String.fromCString(buf)!
	}
	
	public var Pos: Int {
		get { return bufPos + bufStart }
		set {
			if newValue >= fileLen && !stream.CanSeek {
				// Wanted position is after buffer and the stream
				// is not seek-able e.g. network or console,
				// thus we have to read the stream manually till
				// the wanted position is in sight.
				while newValue >= fileLen && ReadNextStreamChunk() > 0 {}
			}
			
			if newValue < 0 || newValue > fileLen {
				assert(true, "buffer out of bounds access, position: \(newValue)")
			}
			
			if newValue >= bufStart && newValue < bufStart + bufLen { // already in buffer
				bufPos = newValue - bufStart
				//			} else if (stream != null) { // must be swapped in
				//				stream.Seek(value, SeekOrigin.Begin);
				//				bufLen = stream.Read(buf, 0, buf.Length);
				//				bufStart = newValue; bufPos = 0;
			} else {
				// set the position to the end of the file, Pos will return fileLen.
				bufPos = fileLen - bufStart
			}
		}
	}
	
	// Read the next chunk of bytes from the stream, increases the buffer
	// if needed and updates the fields fileLen and bufLen.
	// Returns the number of bytes read.
	private func ReadNextStreamChunk() -> Int {
		let free = buf.count - bufLen
		var read = 0
		if free == 0 {
			// in the case of a growing input stream
			// we can neither seek in the stream, nor can we
			// foresee the maximum length, thus we must adapt
			// the buffer size on demand.
			var newBuf = [UInt8](count:bufLen * 2, repeatedValue: 0)  // [bufLen * 2];
			newBuf[0..<bufLen] = buf[0..<bufLen]
			read = stream.read(&buf, maxLength:bufLen)
			newBuf[bufLen..<bufLen*2] = buf[0..<bufLen]
			buf = newBuf
		} else {
			read = stream.read(&buf, maxLength:free)
		}
		if read > 0 {
			bufLen = (bufLen + read); fileLen = bufLen
			return read
		}
		// end of stream reached
		return 0
	}
}

//-----------------------------------------------------------------------------------
// UTF8Buffer
//-----------------------------------------------------------------------------------
public class UTF8Buffer: Buffer {
	
	public override func Read() -> Int {
		var ch: Int
		repeat {
			ch = super.Read()
			// until we find a utf8 start (0xxxxxxx or 11xxxxxx)
		} while ch >= 128 && (ch & 0xC0) != 0xC0 && ch != Buffer.EOF
		if ch < 128 || ch == Buffer.EOF {
			// nothing to do, first 127 chars are the same in ascii and utf8
			// 0xxxxxxx or end of file character
		} else if (ch & 0xF0) == 0xF0 {
			// 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
			let c1 = ch & 0x07; ch = super.Read()
			let c2 = ch & 0x3F; ch = super.Read()
			let c3 = ch & 0x3F; ch = super.Read()
			let c4 = ch & 0x3F
			ch = (((((c1 << 6) | c2) << 6) | c3) << 6) | c4
		} else if (ch & 0xE0) == 0xE0 {
			// 1110xxxx 10xxxxxx 10xxxxxx
			let c1 = ch & 0x0F; ch = super.Read()
			let c2 = ch & 0x3F; ch = super.Read()
			let c3 = ch & 0x3F
			ch = (((c1 << 6) | c2) << 6) | c3;
		} else if (ch & 0xC0) == 0xC0 {
			// 110xxxxx 10xxxxxx
			let c1 = ch & 0x1F; ch = super.Read()
			let c2 = ch & 0x3F
			ch = (c1 << 6) | c2
		}
		return ch
	}
}

public class Scanner {
	let EOL : Character = "\n"
	let eofSym = 0 /* pdt */
	let maxT = 41
	let noSym = 41
	
	var buffer: Buffer?			// scanner buffer
	
	var t = Token()				// current token
	var ch: Character = "\0"    // current input character
	var pos = 0					// byte position of current character
	var charPos = 0				// position by unicode characters starting with 0
	var col = 0					// column number of current character
	var line = 0				// line number of current character
	var oldEols = 0				// EOLs that appeared in a comment;
	static var start: [Int: Int] { // maps first token character to start state
		var result = [Int: Int]()
		for i in 65...90  {  result[i] = 1 }
		for i in 95...95  {  result[i] = 1 }
		for i in 97...122 {  result[i] = 1 }
		for i in 48...57  {  result[i] = 2 }
		result[34] = 12;
		result[39] = 5;
		result[36] = 13;
		result[61] = 16;
		result[46] = 31;
		result[43] = 17;
		result[45] = 18;
		result[60] = 32;
		result[62] = 20;
		result[124] = 23;
		result[40] = 33;
		result[41] = 24;
		result[91] = 25;
		result[93] = 26;
		result[123] = 27;
		result[125] = 28;
		result[Buffer.EOF] = -1
		return result
	}
	
	var tokens = Token()  // list of tokens already peeked (first token is a dummy)
	var pt = Token()      // current peek token
	
	var tval = ""		  // text of current token
	var tlen = 0          // length of current token
	
	public init(fileName: String) {
		if let stream = NSInputStream(fileAtPath: fileName) {
			stream.open()
			if stream.hasBytesAvailable {
				buffer = Buffer(s: stream, isUserStream: false)
			} else {
				assert(false, "Cannot open file " + fileName)
			}
		} else {
			assert(false, "Cannot open file " + fileName)
		}
		Init()
	}
	
	public init (s: NSInputStream) {
		buffer = Buffer(s: s, isUserStream: true)
		Init()
	}
	
	func Init() {
		pos = -1; line = 1; col = 0; charPos = -1
		oldEols = 0
		NextCh()
		if ch == "\u{0EF}" { // check optional byte order mark for UTF-8
			NextCh(); let ch1 = ch
			NextCh(); let ch2 = ch
			if ch1 != "\u{0BB}" || ch2 != "\u{0BF}" {
				assert(false, "illegal byte order mark: EF \(ch1) \(ch2)")
			}
			buffer = UTF8Buffer(b: buffer!); col = 0; charPos = -1
			NextCh()
		}
		tokens = Token(); pt = tokens  // first token is a dummy
	}
	
	func NextCh() {
		if oldEols > 0 {
			ch = EOL; oldEols--
		} else {
			let nl: Character = "\n"
			pos = buffer!.Pos
			// buffer reads unicode chars, if UTF8 has been detected
			ch = Character(buffer!.Read()); col++; charPos++
			// replace isolated "\r" by "\n" in order to make
			// eol handling uniform across Windows, Unix and Mac
			if ch == "\r" && buffer!.Peek() != nl { ch = EOL }
			if ch == EOL { line++; col = 0 }
		}
	}
	
	func AddCh() {
		if ch != Buffer.EOF {
			tval.append(ch)
			NextCh()
		}
	}
	
	func Comment0() -> Bool {
		var level = 1; let pos0 = pos; let line0 = line; let col0 = col; let charPos0 = charPos
		NextCh()
		if ch == "/" {
			NextCh()
			for ;; {
				if ch == 10 {
					level--;
					if level == 0 { oldEols = line - line0; NextCh(); return true }
					NextCh()
				} else if ch == Buffer.EOF {
					return false
				} else {
					NextCh()
				}
			}
		} else {
			buffer!.Pos = pos0; NextCh(); line = line0; col = col0; charPos = charPos0
		}
		return false
	}
	
	func Comment1() -> Bool {
		var level = 1; let pos0 = pos; let line0 = line; let col0 = col; let charPos0 = charPos
		NextCh()
		if ch == "*" {
			NextCh()
			for ;; {
				if ch == "*" {
					NextCh()
					if ch == "/" {
						level--
						if level == 0 { oldEols = line - line0; NextCh(); return true }
						NextCh()
					}
				} else if ch == "/" {
					NextCh()
					if ch == "*" {
						level++; NextCh()
					}
				} else if ch == Buffer.EOF {
					return false
				} else {
					NextCh()
				}
			}
		} else {
			buffer!.Pos = pos0; NextCh(); line = line0; col = col0; charPos = charPos0
		}
		return false
	}
	
	
	func CheckLiteral() {
		switch t.val {
		case "COMPILER": t.kind = 6
		case "IGNORECASE": t.kind = 7
		case "CHARACTERS": t.kind = 8
		case "TOKENS": t.kind = 9
		case "PRAGMAS": t.kind = 10
		case "COMMENTS": t.kind = 11
		case "FROM": t.kind = 12
		case "TO": t.kind = 13
		case "NESTED": t.kind = 14
		case "IGNORE": t.kind = 15
		case "PRODUCTIONS": t.kind = 16
		case "END": t.kind = 19
		case "ANY": t.kind = 23
		case "WEAK": t.kind = 29
		case "SYNC": t.kind = 36
		case "IF": t.kind = 37
		case "CONTEXT": t.kind = 38
		default: break
		}
	}
	
	func NextToken() -> Token {
        while ch == " " || ch >= "\u{9}" && ch <= "\u{A}" || ch == 13 { NextCh() }
		if ch == "/" && Comment0() || ch == "/" && Comment1() { return NextToken() }
		var recKind = noSym
		var recEnd = pos
		t = Token()
		t.pos = pos; t.col = col; t.line = line; t.charPos = charPos
		var state = Scanner.start[ch.unicodeValue()] ?? 0
		tval = ""; AddCh()
		
		loop: repeat {
			switch state {
			case -1: t.kind = eofSym; break loop // NextCh already done
			case 0:
				if recKind != noSym {
					tlen = recEnd - t.pos
					SetScannerBehindT()
				}
				t.kind = recKind; break loop
				// NextCh already done
			case 1:
				recEnd = pos; recKind = 1
				if ch >= "0" && ch <= "9" || ch >= "A" && ch <= "Z" || ch == "_" || ch >= "a" && ch <= "z" { AddCh(); state = 1 }
				else { t.kind = 1;	t.val = tval; CheckLiteral(); return t }
			case 2:
				recEnd = pos; recKind = 2
				if ch >= "0" && ch <= "9"  { AddCh(); state = 2 }
				else { t.kind = 2; break loop }
			case 3:
				t.kind = 3; break loop
			case 4:
				t.kind = 4; break loop
			case 5:
                if ch <= "\u{9}" || ch >= "\u{B}" && ch <= "\u{C}" || ch >= "\u{D}" && ch <= "&" ||
                   ch >= "(" && ch <= "[" || ch >= "]" && ch <= "\u{FFFF}" { AddCh(); state = 6 }
				else if ch == "\u{5C}" { AddCh(); state = 7 }
				else { state = 0 }
			case 6:
                if ch == "\u{27}" { AddCh(); state = 9 }
				else { state = 0 }
			case 7:
				if ch >= " " && ch <= "~" { AddCh(); state = 8 }
				else { state = 0 }
			case 8:
				if ch >= "0" && ch <= "9" || ch >= "a" && ch <= "f" {AddCh(); state = 8 }
				else if ch == "\u{27}" { AddCh(); state = 9 }
				else { state = 0 }
			case 9:
				t.kind = 5; break loop
			case 10:
				recEnd = pos; recKind = 42;
				if ch >= "0" && ch <= "9" || ch >= "A" && ch <= "Z" || ch == "_" || ch >= "a" && ch <= "z" {AddCh(); state = 10 }
				else { t.kind = 42; break loop }
			case 11:
				recEnd = pos; recKind = 43;
				if (ch >= "-" && ch <= "." || ch >= "0" && ch <= ":" || ch >= "A" && ch <= "Z" || ch == "_" || ch >= "a" && ch <= "z") {AddCh(); state = 11 }
				else { t.kind = 43; break loop }
			case 12:
				if ch <= "\u{9}" || ch >= "\u{B}" && ch <= "\u{C}" || ch >= "\u{E}" && ch <= "!" ||
                   ch >= "#" && ch <= "[" || ch >= "]" && ch <= "\u{FFFF}" { AddCh(); state = 12 }
				else if ch == 10 || ch == 13 { AddCh(); state = 4 }
				else if ch == "\"" { AddCh(); state = 3 }
				else if ch == 92 { AddCh(); state = 14 }
				else { state = 0 }
			case 13:
				recEnd = pos; recKind = 42
                if ch >= "0" && ch <= "9" { AddCh(); state = 10 }
				else if (ch >= "A" && ch <= "Z" || ch == "_" || ch >= "a" && ch <= "z") { AddCh(); state = 15 }
				else { t.kind = 42; break loop }
			case 14:
				if (ch >= " " && ch <= "~") { AddCh(); state = 12 }
				else {state = 0 }
			case 15:
				recEnd = pos; recKind = 42;
				if (ch >= "0" && ch <= "9") { AddCh(); state = 10 }
				else if (ch >= "A" && ch <= "Z" || ch == "_" || ch >= "a" && ch <= "z") {AddCh(); state = 15 }
				else if (ch == "=") { AddCh(); state = 11 }
				else { t.kind = 42; break loop }
			case 16:
				t.kind = 17; break loop
			case 17:
				t.kind = 20; break loop
			case 18:
				t.kind = 21; break loop
			case 19:
				t.kind = 22; break loop
			case 20:
				t.kind = 25; break loop
			case 21:
				t.kind = 26; break loop
			case 22:
				t.kind = 27; break loop
			case 23:
				t.kind = 28; break loop
			case 24:
				t.kind = 31; break loop
			case 25:
				t.kind = 32; break loop
			case 26:
				t.kind = 33; break loop
			case 27:
				t.kind = 34; break loop
			case 28:
				t.kind = 35; break loop
			case 29:
				t.kind = 39; break loop
			case 30:
				t.kind = 40; break loop
			case 31:
				recEnd = pos; recKind = 18
				if ch == "." { AddCh(); state = 19 }
				else if ch == ">" { AddCh(); state = 22 }
				else if ch == ")" { AddCh(); state = 30 }
				else { t.kind = 18; break loop }
			case 32:
				recEnd = pos; recKind = 24;
				if ch == "." { AddCh(); state = 21 }
				else { t.kind = 24; break loop }
			case 33:
				recEnd = pos; recKind = 30;
				if ch == "." { AddCh(); state = 29 }
				else { t.kind = 30; break loop }
			default: break loop
			}
		} while true
		t.val = tval
		return t
	}
	
	private func SetScannerBehindT() {
		buffer!.Pos = t.pos
		NextCh()
		line = t.line; col = t.col; charPos = t.charPos
		for _ in 0..<tlen { NextCh() }
	}
	
	// get the next token (possibly a token already seen during peeking)
	public func Scan () -> Token {
		if tokens.next == nil {
			return NextToken()
		} else {
			tokens = tokens.next!; pt = tokens
			return tokens
		}
	}
	
	// peek for the next token, ignore pragmas
	public func Peek () -> Token {
		repeat {
			if pt.next == nil {
				pt.next = NextToken()
			}
			pt = pt.next!
		} while pt.kind > maxT // skip pragmas
		
		return pt
	}
	
	// make sure that peeking starts at the current scan position
	public func ResetPeek () { pt = tokens; }
}

