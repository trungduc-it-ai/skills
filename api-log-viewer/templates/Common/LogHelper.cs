using System;
using System.IO;

namespace %%NAMESPACE%%.Common
{
    public static class LogHelper
    {
        private static readonly object bWrite = new object();

        // LogMaintenance khoá cùng object này khi xoá file/thư mục log - tránh xoá thư mục ngày đúng
        // lúc RegLog vừa tạo xong mà chưa kịp ghi file.
        internal static object SyncRoot => bWrite;

        public static void RegLog(string IMEI, string Mess)
        {
            lock (bWrite)
            {
                string root = "Logs";
                string Year = DateTime.Now.Year.ToString();
                string Month = DateTime.Now.Month.ToString();
                string day = DateTime.Now.Day.ToString();
                if (!Directory.Exists(root))
                    Directory.CreateDirectory(root);
                string pathYear = root + @"\" + Year;
                if (!Directory.Exists(pathYear))
                    Directory.CreateDirectory(pathYear);
                string pathMonth = pathYear + @"\" + Month;
                if (!Directory.Exists(pathMonth))
                    Directory.CreateDirectory(pathMonth);
                string pathDay = pathMonth + @"\" + day;
                if (!Directory.Exists(pathDay))
                    Directory.CreateDirectory(pathDay);
                string FilePath = pathDay + @"\" + IMEI + ".txt";

                try
                {
                    using (FileStream fs = File.Open(FilePath, FileMode.Append))
                    using (StreamWriter bw = new StreamWriter(fs))
                    {
                        string me = "DateTime: " + DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss") + ", Data: " + Mess + "\r\n";
                        bw.Write(me);
                    }
                }
                catch
                {
                    // giữ nguyên hành vi cũ: lỗi ghi log không được throw ra ngoài
                }
            }
        }
    }
}
